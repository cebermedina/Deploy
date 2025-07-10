param(
    [Parameter(Mandatory = $true)]
    [string]$repo,

    [Parameter(Mandatory = $true)]
    [string]$rdsInstanceId
)

$region = "us-east-1"
$clusterName = "admin-api-cluster"
$serviceName = "$repo-service"
$lbName = "$repo-lb"
$tgName = "$repo-tg"

Write-Host "🛑 Iniciando limpieza de entorno para $repo en región $region..." -ForegroundColor Yellow
# 1. Eliminar el servicio ECS
Write-Host "Eliminando servicio ECS '$serviceName'..." -ForegroundColor Yellow
aws ecs delete-service --cluster $clusterName --service $serviceName --force --region $region

# Esperar a que el servicio sea eliminado completamente
# do {
#     Start-Sleep -Seconds 5
#     $status = aws ecs describe-services --cluster $clusterName --services $serviceName --region $region --query "services[0].status" --output text 2>$null
#     Write-Host "Esperando a que el servicio ECS sea eliminado... (estado: $status)" -ForegroundColor Cyan
# } while ($status -ne "INACTIVE")


# Reducir desired count a 0 (detiene tareas activas)
Write-Host "Reduciendo desired count del servicio ECS '$serviceName' a 0..." -ForegroundColor Cyan
$serviceExists = aws ecs describe-services --cluster $clusterName --services $serviceName --query "services[0].status" --output text 2>$null
if ($serviceExists -eq "ACTIVE") {
    aws ecs update-service `
        --cluster $clusterName `
        --service $serviceName `
        --desired-count 0 | Out-Null
    Write-Host "✅ Servicio detenido (desired count: 0)" -ForegroundColor Green
} else {
    Write-Host "⚠️  Servicio no existe o ya está detenido." -ForegroundColor Yellow
}

# Obtener Load Balancer ARN
$lbArn = aws elbv2 describe-load-balancers --names $lbName --query "LoadBalancers[0].LoadBalancerArn" --output text 2>$null
if ($lbArn -ne "None" -and $lbArn) {
    # Obtener Listener
    $listenerArn = aws elbv2 describe-listeners --load-balancer-arn $lbArn --query 'Listeners[0].ListenerArn' --output text 2>$null
    if ($listenerArn -ne "None" -and $listenerArn) {
        Write-Host "Eliminando listener..." -ForegroundColor Cyan
        aws elbv2 delete-listener --listener-arn $listenerArn
        Write-Host "✅ Listener eliminado." -ForegroundColor Green
    }

    Write-Host "Eliminando Load Balancer..." -ForegroundColor Cyan
    aws elbv2 delete-load-balancer --load-balancer-arn $lbArn
    Write-Host "✅ Load Balancer eliminado." -ForegroundColor Green
} else {
    Write-Host "⚠️  Load Balancer '$lbName' no existe." -ForegroundColor Yellow
}

# Obtener Target Group ARN
$tgArn = aws elbv2 describe-target-groups --names $tgName --query "TargetGroups[0].TargetGroupArn" --output text 2>$null
if ($tgArn -ne "None" -and $tgArn) {
    Write-Host "Eliminando Target Group..." -ForegroundColor Cyan
    aws elbv2 delete-target-group --target-group-arn $tgArn
    Write-Host "✅ Target Group eliminado." -ForegroundColor Green
} else {
    Write-Host "⚠️  Target Group '$tgName' no existe." -ForegroundColor Yellow
}

# ========== Detener RDS (Stop Temporarily) ==========
Write-Host "Deteniendo temporalmente la instancia RDS '$rdsInstanceId'..." -ForegroundColor Yellow
aws rds stop-db-instance --db-instance-identifier $rdsInstanceId --region $region
Write-Host "✅ Solicitud para detener la instancia RDS enviada." -ForegroundColor Green

#  Eliminar cluster ECS
Write-Host "🧨 Eliminando cluster ECS '$clusterName'..."
aws ecs delete-cluster --cluster $clusterName --region $region | Out-Null
Write-Host "✅ Cluster ECS eliminado correctamente." -ForegroundColor Green

# Eliminar repositorio ECR
$accountId = (aws sts get-caller-identity --query Account --output text)
$ecrCheck = aws ecr describe-repositories --repository-names $repo --region $region 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "Eliminando repositorio ECR '$repo'..."
    aws ecr delete-repository --repository-name $repo --force --region $region
    Write-Host "Repositorio ECR eliminado correctamente." -ForegroundColor Green
} else {
    Write-Host "Repositorio ECR '$repo' no existe o ya fue eliminado." -ForegroundColor Yellow
}

# Eliminar Internet Gateway si existe
# $igwId = (aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$vpcId --query "InternetGateways[0].InternetGatewayId" --output text --region $region)
# if ($igwId -ne "None") {
#     Write-Host "Desasociando y eliminando Internet Gateway: $igwId" -ForegroundColor Yellow
#     aws ec2 detach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId --region $region
#     aws ec2 delete-internet-gateway --internet-gateway-id $igwId --region $region
#     Write-Host "Internet Gateway eliminado." -ForegroundColor Green
# }



Write-Host "🎉 Limpieza completa. No se incurrirá en costos por tareas activas, Load Balancer o TG." -ForegroundColor Cyan
