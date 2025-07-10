# Variables
$containerName = "sqlserver2022"
$imageName = "mcr.microsoft.com/mssql/server:2022-lts"
$volumeName = "sqlserver_data_volume"
$saPassword = "YourStrong!Passw0rd"
$port = 1433

# Verifica si el volumen ya existe
$volumeExists = docker volume ls --format "{{.Name}}" | Where-Object { $_ -eq $volumeName }

if (-not $volumeExists) {
    Write-Host "🗂️  Creating Docker volume '$volumeName'..."
    docker volume create $volumeName
} else {
    Write-Host "✅ Docker volume '$volumeName' already exists."
}

# Verifica si el contenedor ya está corriendo
$containerExists = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $containerName }

if ($containerExists) {
    Write-Host "🛑 Stopping and removing existing container '$containerName'..."
    docker stop $containerName | Out-Null
    docker rm $containerName | Out-Null
}

# Ejecuta el contenedor
Write-Host "🚀 Starting SQL Server container '$containerName'..."
docker run -e "ACCEPT_EULA=Y" `
           -e "MSSQL_SA_PASSWORD=$saPassword" `
           -p $port:1433 `
           --name $containerName `
           -v $volumeName:/var/opt/mssql `
           -d $imageName

Write-Host "✅ SQL Server is running on localhost:$port"
Write-Host "🔐 SA Password: $saPassword"
