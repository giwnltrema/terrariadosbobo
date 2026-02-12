param(
  [string]$TerraformDir = "terraform"
)

$ErrorActionPreference = "Stop"

Write-Host "[1/4] terraform init"
terraform -chdir=$TerraformDir init

Write-Host "[2/4] terraform validate"
terraform -chdir=$TerraformDir validate

Write-Host "[3/4] terraform apply"
terraform -chdir=$TerraformDir apply -auto-approve

Write-Host "[4/4] Estado dos pods"
kubectl get pods -A
