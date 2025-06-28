param (
    [Parameter(Mandatory = $true)]
    [string]$repo,
     [Parameter(Mandatory = $true)]
    [string]$rdsInstanceId
)

# ==========================
# Configuración
# ==========================
$region = "us-east-1"
$imageTag = "latest"

# Obtener la cuenta de AWS
$accountId = (aws sts get-caller-identity --query Account --output text)
$ecrUrl = "${accountId}.dkr.ecr.${region}.amazonaws.com"
$fullImageName = "${ecrUrl}/${repo}:${imageTag}"

Write-Host "Repositorio completo: $fullImageName" -ForegroundColor Cyan

# 1. Verificar si el repositorio existe
  aws ecr describe-repositories --repository-names $repo --region $region >$null 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Repositorio no encontrado. Creando..." -ForegroundColor Yellow
    aws ecr create-repository --repository-name $repo --region $region
} else {
    Write-Host "Repositorio ya existe" -ForegroundColor Green
}

# ==========================
# 2. Login en Amazon ECR
# ==========================
Write-Host "Autenticando con ECR..." -ForegroundColor Cyan
aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $ecrUrl

# ==========================
# 3. Etiquetar y subir a ECR
# ==========================
Write-Host "Etiquetando imagen..." -ForegroundColor Cyan
docker tag "${repo}:${imageTag}" $fullImageName

Write-Host "Subiendo imagen a ECR..." -ForegroundColor Cyan
docker push $fullImageName
$finalMessage = "Imagen subida correctamente $fullImageName"
Write-Host $finalMessage -ForegroundColor Green

.\deploy-fargate.ps1 -repo $repo
aws rds start-db-instance --db-instance-identifier $rdsInstanceId --region $region

