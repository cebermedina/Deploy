# 🚀 Development Deployment Instructions for IdentityServer and API

This guide explains how to build Docker images, deploy them to AWS using Fargate, and manage resources during development.

---

## 🔐 1. Authenticate to AWS

Before running any commands, ensure you're authenticated in AWS:

```bash
aws configure
```

Provide your credentials, region (`us-east-1`), and output format (`json` or `text`).

---

## 🐳 2. Build Docker Images

Ensure Docker Desktop is running.

### 🏗️ Build Identity Server Image

```powershell
cd C:\Git\IdentityServerAdmin
Get-ChildItem -Recurse -Include bin,obj | Remove-Item -Recurse -Force
docker build -t admin-identity-api -f ./src/Admin.IdentityServer.STS.Identity/Dockerfile .
```

### 🏗️ Build Admin API Image

```powershell
cd C:\Git\AdminAPI\source
Get-ChildItem -Recurse -Include bin,obj | Remove-Item -Recurse -Force
docker build -t admin-api -f ./API/Dockerfile .
```

---

## ☁️ 3. Deploy to AWS (Create Resources)

Use the deployment script to create all AWS resources needed for your service.

### ⚙️ Identity Server

```powershell
cd C:\Git\Deploy
.\build-and-push.ps1 -repo "admin-identity-api" -rdsInstanceId admin
```

### ⚙️ Admin API

```powershell
cd C:\Git\Deploy
.\build-and-push.ps1 -repo "admin-api" -rdsInstanceId admin
```

This will:
- Push the Docker image to ECR
- Create (or reuse) VPC, Subnets, Security Group, IAM Role
- Register ECS Task Definition and Service
- Set up Load Balancer, Target Group, and Listener
- Associate database connection if needed

---

## ⛔ 4. Stop Resources (Development Cleanup)

To reduce costs during development, stop services and RDS instance:

### 🧹 Stop Identity Server resources

```powershell
.\cleanup-dev.ps1 -repo admin-identity-api -rdsInstanceId admin
```

### 🧹 Stop Admin API resources

```powershell
.\cleanup-dev.ps1 -repo admin-api -rdsInstanceId admin
```

## ✅ Notes

- You **don’t need to delete** VPC, Subnet, Internet Gateway, Route Table, or Security Group between development sessions.
- Keeping those resources reduces future deployment time and effort.
---

End of file.