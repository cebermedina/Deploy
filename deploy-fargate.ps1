param(
    [Parameter(Mandatory = $true)]
    [string]$repo
)

$region = "us-east-1"
$clusterName = "admin-api-cluster"
$imageTag = "latest"
$vpcName = "AdminApiVPC"
$subnetName = "AdminApiSubnet"
$sgName = "admin-api-sg"

$lbName = "$repo-lb"
$tgName = "$repo-tg"
$taskName = "$repo-task"
$serviceName = "$repo-service"

$accountId = (aws sts get-caller-identity --query Account --output text)
$ecrUrl = "${accountId}.dkr.ecr.${region}.amazonaws.com"
$fullImageName = "${ecrUrl}/${repo}:${imageTag}"

Write-Host "Imagen a usar: $fullImageName" -ForegroundColor Cyan

# ================= VPC =================
$vpcId = (aws ec2 describe-vpcs --filters Name=tag:Name,Values=$vpcName --query "Vpcs[0].VpcId" --output text --region $region)
if ($vpcId -eq "None") {
    $vpcId = (aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text --region $region)
    aws ec2 create-tags --resources $vpcId --tags Key=Name,Value=$vpcName --region $region
    Write-Host "VPC creada: $vpcId" -ForegroundColor Green
} else {
    Write-Host "Usando VPC existente: $vpcId" -ForegroundColor Cyan
}

# ================= Subnets =================
$existingSubnets = (aws ec2 describe-subnets --filters Name=vpc-id,Values=$vpcId --query "Subnets[*].{Id:SubnetId,Az:AvailabilityZone,Cidr:CidrBlock}" --output json --region $region | ConvertFrom-Json)

# Obtener zonas disponibles
$azs = (aws ec2 describe-availability-zones --query "AvailabilityZones[*].ZoneName" --output text --region $region).Split()

# Obtener CIDRs ya usados
$usedCidrs = $existingSubnets.Cidr

function Get-AvailableCidr {
    param($base = "10.0", $start = 1)
    for ($i = $start; $i -lt 255; $i++) {
        $cidr = "$base.$i.0/24"
        if ($usedCidrs -notcontains $cidr) {
            $usedCidrs += $cidr
            return $cidr
        }
    }
    throw "No hay CIDRs disponibles."
}

# ================= Subnets =================
$existingSubnets = (aws ec2 describe-subnets `
    --filters Name=vpc-id,Values=$vpcId `
    --query "Subnets[*].{Id:SubnetId,Az:AvailabilityZone,Cidr:CidrBlock}" `
    --output json --region $region | ConvertFrom-Json)

# Agrupar subnets por AZ
$subnetsByAz = @{}
foreach ($subnet in $existingSubnets) {
    if (-not $subnetsByAz.ContainsKey($subnet.Az)) {
        $subnetsByAz[$subnet.Az] = $subnet.Id
    }
}

# Obtener todas las zonas disponibles
$azs = (aws ec2 describe-availability-zones `
    --query "AvailabilityZones[*].ZoneName" `
    --output text --region $region).Split()

# Obtener CIDRs ya usados
$usedCidrs = $existingSubnets.Cidr

function Get-AvailableCidr {
    param($base = "10.0", $start = 1)
    for ($i = $start; $i -lt 255; $i++) {
        $cidr = "$base.$i.0/24"
        if ($usedCidrs -notcontains $cidr) {
            $usedCidrs += $cidr
            return $cidr
        }
    }
    throw "No hay CIDRs disponibles."
}

# Inicializar
$subnetId1 = $null
$subnetId2 = $null

$azKeys = @($subnetsByAz.Keys)

if ($azKeys.Count -ge 2) {
    # ✅ Usar 2 subnets existentes en AZ distintas
    $subnetId1 = $subnetsByAz[$azKeys[0]]
    $subnetId2 = $subnetsByAz[$azKeys[1]]
    Write-Host "Usando subnets existentes: $subnetId1 y $subnetId2" -ForegroundColor Cyan
}
elseif ($azKeys.Count -eq 1) {
    # ✅ Solo hay una subnet → usarla y crear la segunda
    $az1 = $azKeys[0]
    $subnetId1 = $subnetsByAz[$az1]

    $az2 = ($azs | Where-Object { $_ -ne $az1 })[0]
    $cidr2 = Get-AvailableCidr

    Write-Host "Solo se encontró una subnet. Creando otra en zona $az2..." -ForegroundColor Yellow
    $subnetId2 = (aws ec2 create-subnet `
        --vpc-id $vpcId `
        --cidr-block $cidr2 `
        --availability-zone $az2 `
        --query 'Subnet.SubnetId' --output text --region $region)
    
    aws ec2 create-tags --resources $subnetId2 `
        --tags Key=Name,Value="${subnetName}2" --region $region

    Write-Host "Subnet creada: $subnetId2" -ForegroundColor Green
}
else {
    # ✅ No hay subnets → crear dos en distintas AZ
    Write-Host "No se encontraron subnets. Creando dos nuevas..." -ForegroundColor Yellow

    $az1 = $azs[0]
    $az2 = $azs[1]

    $cidr1 = Get-AvailableCidr -start 1
    $cidr2 = Get-AvailableCidr -start 2

    $subnetId1 = (aws ec2 create-subnet `
        --vpc-id $vpcId `
        --cidr-block $cidr1 `
        --availability-zone $az1 `
        --query 'Subnet.SubnetId' --output text --region $region)

    aws ec2 create-tags --resources $subnetId1 `
        --tags Key=Name,Value="${subnetName}1" --region $region

    $subnetId2 = (aws ec2 create-subnet `
        --vpc-id $vpcId `
        --cidr-block $cidr2 `
        --availability-zone $az2 `
        --query 'Subnet.SubnetId' --output text --region $region)

    aws ec2 create-tags --resources $subnetId2 `
        --tags Key=Name,Value="${subnetName}2" --region $region

    Write-Host "Subnets creadas: $subnetId1 y $subnetId2" -ForegroundColor Green
}

# ✅ Concatenar para usar en Load Balancer o ECS
$subnetIds = @($subnetId1, $subnetId2)

# ================= Internet Gateway =================
$igwId = (aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$vpcId --query "InternetGateways[0].InternetGatewayId" --output text --region $region)
if ($igwId -eq "None") {
    $igwId = (aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text --region $region)
    aws ec2 attach-internet-gateway --vpc-id $vpcId --internet-gateway-id $igwId --region $region
      Write-Host "InternetGateway creada: $igwId" -ForegroundColor Green
}
else {
    Write-Host "Usando InternetGateway existente: $igwId" -ForegroundColor Cyan
}

# --- Route Table ---
$routeTableId = (aws ec2 describe-route-tables --filters Name=vpc-id,Values=$vpcId --query "RouteTables[0].RouteTableId" --output text)
$hasRoute = aws ec2 describe-route-tables --route-table-ids $routeTableId --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0']" --output text
if (-not $hasRoute) {
    Write-Host "Agregando ruta pública..." -ForegroundColor Yellow
    aws ec2 create-route --route-table-id $routeTableId --destination-cidr-block 0.0.0.0/0 --gateway-id $igwId
    aws ec2 associate-route-table --subnet-id $subnetId1 --route-table-id $routeTableId
     Write-Host "Route-table creada: $routeTableId" -ForegroundColor Green
} else {
    Write-Host "Usando Route-table existente: $routeTableId" -ForegroundColor Cyan
}

# --- Security Group ---
$sgId = (aws ec2 describe-security-groups --filters Name=group-name,Values=$sgName Name=vpc-id,Values=$vpcId --query "SecurityGroups[0].GroupId" --output text)
if ($sgId -eq "None") {
    Write-Host "Creando Security Group..." -ForegroundColor Yellow
    $sgId = (aws ec2 create-security-group --group-name $sgName --description "Allow HTTP" --vpc-id $vpcId --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 80 --cidr 0.0.0.0/0
    Write-Host "Security Group creado: $sgId" -ForegroundColor Green
} else {
    Write-Host "Usando Security Group existente: $sgId" -ForegroundColor Cyan
}

# 🔹 Crear rol de ejecución si no existe
$roleName = "ecsTaskExecutionRole"
$roleCheck = aws iam get-role --role-name $roleName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Rol $roleName no existe. Creándolo..." -ForegroundColor Yellow

    $assumeRolePolicyPath = "assume-role-policy.json"
@'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
'@ | Out-File -Encoding ASCII -FilePath $assumeRolePolicyPath

    aws iam create-role --role-name $roleName --assume-role-policy-document file://$assumeRolePolicyPath

    Remove-Item $assumeRolePolicyPath
    aws iam attach-role-policy --role-name $roleName --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    Start-Sleep -Seconds 10
    $executionRoleArn = (aws iam get-role --role-name $roleName --query 'Role.Arn' --output text)
    Write-Host "Rol creado: $roleName $executionRoleArn" -ForegroundColor Green
} else {
    $executionRoleArn = (aws iam get-role --role-name $roleName --query 'Role.Arn' --output text)
    Write-Host "Usando rol existente: $executionRoleArn " -ForegroundColor Cyan
}

# ========== ECS Cluster ==========
$clusterExists = aws ecs describe-clusters --clusters $clusterName --query "clusters[0].status" --output text 2>$null
if ($clusterExists -ne "ACTIVE") {
    aws ecs create-cluster --cluster-name $clusterName
    Write-Host "Cluster creado: $clusterName" -ForegroundColor Green
} else {
    Write-Host "Cluster existente: $clusterName" -ForegroundColor Cyan
}

# ========== Registrar Task Definition ==========
$taskDefFile = "task-def.json"
@"
{
  "family": "$taskName",
  "executionRoleArn": "$executionRoleArn",
  "networkMode": "awsvpc",
  "containerDefinitions": [
    {
      "name": "admin-container",
      "image": "$fullImageName",
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "ASPNETCORE_ENVIRONMENT",
          "value": "Development"
        }
      ],
      "essential": true
    }
  ],
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512"
}
"@ | Out-File -Encoding ascii -FilePath $taskDefFile

aws ecs register-task-definition --cli-input-json file://$taskDefFile
Remove-Item $taskDefFile
Write-Host "✅ Task Definition registrada con nueva imagen y variables." -ForegroundColor Green

# ========== Load Balancer y Target Group ==========
$lbArn = (aws elbv2 describe-load-balancers --names $lbName --query "LoadBalancers[0].LoadBalancerArn" --output text 2>$null)

if (-not $lbArn -or $lbArn -eq "None") {
    $lbArn = (aws elbv2 create-load-balancer --name $lbName --subnets $subnetIds --security-groups $sgId --scheme internet-facing --type application --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    Write-Host "Load Balancer creado: $lbArn" -ForegroundColor Green
} else {
    Write-Host "Load Balancer existente: $lbArn" -ForegroundColor Cyan
}

# Buscar TG existente por nombre
$tgDesc = aws elbv2 describe-target-groups --names $tgName --output json 2>$null | ConvertFrom-Json

if (-not $tgDesc.TargetGroups) {
    # No existe, crear nuevo
    $tgArn = (aws elbv2 create-target-group `
        --name $tgName `
        --protocol HTTP `
        --port 80 `
        --vpc-id $vpcId `
        --target-type ip `
        --query 'TargetGroups[0].TargetGroupArn' `
        --output text)
    Write-Host "Target Group creado: $tgArn" -ForegroundColor Green
}
else {
    $existingTgVpc = $tgDesc.TargetGroups[0].VpcId
    $tgArn = $tgDesc.TargetGroups[0].TargetGroupArn

    if ($existingTgVpc -ne $vpcId) {
        Write-Host "⚠️  Target Group existe pero en otra VPC ($existingTgVpc). Eliminando y recreando..." -ForegroundColor Yellow
        aws elbv2 delete-target-group --target-group-arn $tgArn

        $tgArn = (aws elbv2 create-target-group `
            --name $tgName `
            --protocol HTTP `
            --port 80 `
            --vpc-id $vpcId `
            --target-type ip `
            --query 'TargetGroups[0].TargetGroupArn' `
            --output text)
        Write-Host "Target Group recreado: $tgArn" -ForegroundColor Green
    }
    else {
        Write-Host "Target Group existente en la VPC correcta: $tgArn" -ForegroundColor Cyan
    }
}

# ========== HealthCheckPath para Target Group ==========
Write-Host "Verificando configuración de health check en el Target Group..." -ForegroundColor Cyan

# Verifica configuración actual del health check
$currentHealthCheckPath = (aws elbv2 describe-target-groups `
    --target-group-arn $tgArn `
    --query "TargetGroups[0].HealthCheckPath" `
    --output text)

if ($currentHealthCheckPath -ne "/health") {
    Write-Host "Actualizando HealthCheckPath a '/health'..." -ForegroundColor Yellow
    aws elbv2 modify-target-group `
        --target-group-arn $tgArn `
        --health-check-path "/health" `
        --health-check-protocol HTTP `
        --health-check-port "traffic-port" `
        --region $region
    Write-Host "HealthCheckPath actualizado correctamente" -ForegroundColor Green
} else {
    Write-Host "HealthCheckPath ya está configurado correctamente: $currentHealthCheckPath" -ForegroundColor Green
}


$listenerArn = (aws elbv2 describe-listeners --load-balancer-arn $lbArn --query 'Listeners[0].ListenerArn' --output text 2>$null)
if ($listenerArn -eq "None") {
    $listenerArn = (aws elbv2 create-listener --load-balancer-arn $lbArn --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$tgArn --query 'Listeners[0].ListenerArn' --output text)
    Write-Host "Listener creado: $listenerArn"
} else {
    Write-Host "Listener existente:  $listenerArn" -ForegroundColor Cyan
}

# ========== ECS Service ==========
$serviceExists = aws ecs describe-services --cluster $clusterName --services $serviceName --query "services[0].status" --output text 2>$null

if ($serviceExists -eq "ACTIVE") {
    Write-Host "🔄 El servicio ECS '$serviceName' ya existe. Actualizando definición de tarea..." -ForegroundColor Yellow

    aws ecs update-service `
        --cluster $clusterName `
        --service $serviceName `
        --task-definition $taskName `
        --force-new-deployment | Out-Null

    Write-Host "✅ Servicio ECS actualizado exitosamente." -ForegroundColor Green
} else {
    Write-Host "🆕 Creando nuevo servicio ECS '$serviceName'..." -ForegroundColor Yellow

    aws ecs create-service `
        --cluster $clusterName `
        --service-name $serviceName `
        --task-definition $taskName `
        --desired-count 1 `
        --launch-type FARGATE `
        --network-configuration "awsvpcConfiguration={subnets=[$subnetId1,$subnetId2],securityGroups=[$sgId],assignPublicIp=ENABLED}" `
        --load-balancers "targetGroupArn=$tgArn,containerName=admin-container,containerPort=80" | Out-Null

    Write-Host "✅ Servicio ECS creado exitosamente." -ForegroundColor Green
}
