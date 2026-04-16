#!/usr/bin/env pwsh
# scripts/bootstrap-state-backend.ps1

param(
    [Parameter(Mandatory = $true)]
    [string]$BucketName,

    [Parameter(Mandatory = $false)]
    [string]$Region = "eu-west-1",

    [Parameter(Mandatory = $false)]
    [string]$DynamoDBTable = "terraform-state-lock"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-Success([string]$msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}

function Write-Warning([string]$msg) {
    Write-Host "    [WARN] $msg" -ForegroundColor Yellow
}

# ── Validate AWS credentials ───────────────────────────────────────────────

Write-Step "Validating AWS credentials"
$callerIdentity = aws sts get-caller-identity | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "AWS credentials not configured. Run 'aws configure' first." }
Write-Success "Authenticated as: $($callerIdentity.Arn)"

# ── S3 Bucket ─────────────────────────────────────────────────────────────

Write-Step "Creating S3 state bucket: $BucketName"

$existingBucket = aws s3api head-bucket --bucket $BucketName 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Warning "Bucket '$BucketName' already exists — skipping creation."
} else {
    if ($Region -eq "us-east-1") {
        aws s3api create-bucket --bucket $BucketName --region $Region | Out-Null
    } else {
        aws s3api create-bucket `
            --bucket $BucketName `
            --region $Region `
            --create-bucket-configuration LocationConstraint=$Region | Out-Null
    }

    if ($LASTEXITCODE -ne 0) { throw "Failed to create S3 bucket." }
    Write-Success "Bucket created."
}

# Enable versioning
Write-Step "Enabling versioning on $BucketName"
aws s3api put-bucket-versioning `
    --bucket $BucketName `
    --versioning-configuration Status=Enabled | Out-Null
Write-Success "Versioning enabled."

# Enable encryption
Write-Step "Enabling default encryption on $BucketName"
$encryptionConfig = @{
    Rules = @(
        @{
            ApplyServerSideEncryptionByDefault = @{
                SSEAlgorithm = "AES256"
            }
        }
    )
} | ConvertTo-Json -Depth 5 -Compress

aws s3api put-bucket-encryption `
    --bucket $BucketName `
    --server-side-encryption-configuration $encryptionConfig | Out-Null
Write-Success "Encryption enabled."

# Block public access
Write-Step "Blocking public access on $BucketName"
aws s3api put-public-access-block `
    --bucket $BucketName `
    --public-access-block-configuration `
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" | Out-Null
Write-Success "Public access blocked."

# ── DynamoDB lock table ────────────────────────────────────────────────────

Write-Step "Creating DynamoDB lock table: $DynamoDBTable"

$existingTable = aws dynamodb describe-table --table-name $DynamoDBTable --region $Region 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Warning "Table '$DynamoDBTable' already exists — skipping creation."
} else {
    aws dynamodb create-table `
        --table-name $DynamoDBTable `
        --attribute-definitions AttributeName=LockID,AttributeType=S `
        --key-schema AttributeName=LockID,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST `
        --region $Region | Out-Null

    if ($LASTEXITCODE -ne 0) { throw "Failed to create DynamoDB table." }

    Write-Step "Waiting for DynamoDB table to become ACTIVE..."
    aws dynamodb wait table-exists --table-name $DynamoDBTable --region $Region
    Write-Success "DynamoDB table active."
}

# ── Update backend.tf ─────────────────────────────────────────────────────

Write-Step "Patching backend.tf with bucket name"
$backendFile = Join-Path $PSScriptRoot ".." "backend.tf"

if (Test-Path $backendFile) {
    $content = Get-Content $backendFile -Raw
    $content = $content -replace 'REPLACE_WITH_YOUR_STATE_BUCKET', $BucketName
    Set-Content $backendFile $content
    Write-Success "backend.tf updated with bucket: $BucketName"
} else {
    Write-Warning "backend.tf not found — update manually."
}

# ── Summary ───────────────────────────────────────────────────────────────

Write-Host "`n" + ("-" * 60) -ForegroundColor DarkGray
Write-Host "Bootstrap complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  S3 Bucket     : $BucketName"
Write-Host "  DynamoDB Table: $DynamoDBTable"
Write-Host "  Region        : $Region"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Review backend.tf"
Write-Host "  2. Run: terraform init"
Write-Host "  3. Run: terraform plan"
Write-Host ("-" * 60) -ForegroundColor DarkGray