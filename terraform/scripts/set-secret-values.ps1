#!/usr/bin/env pwsh
# scripts/set-secret-values.ps1

param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$Region = "eu-west-1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step([string]$msg)    { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Success([string]$msg) { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Info([string]$msg)    { Write-Host "    [i]  $msg" -ForegroundColor Gray }

# ── Validate AWS credentials ───────────────────────────────────────────────

Write-Step "Validating AWS credentials"
$identity = aws sts get-caller-identity | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "AWS CLI not configured. Run 'aws configure' first." }
Write-Success "Authenticated as: $($identity.Arn)"

# ── Helper: read a secret value interactively or from env ─────────────────

function Get-SecretValue {
    param(
        [string]$Prompt,
        [string]$EnvVarName,
        [bool]$IsPassword = $true
    )

    $envValue = [System.Environment]::GetEnvironmentVariable($EnvVarName)
    if ($envValue) {
        Write-Info "Using $EnvVarName from environment."
        return $envValue
    }

    if ($IsPassword) {
        $secure = Read-Host -Prompt $Prompt -AsSecureString
        $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return  [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } else {
        return Read-Host -Prompt $Prompt
    }
}

# ── Helper: write a JSON secret to Secrets Manager ────────────────────────

function Set-Secret {
    param(
        [string]$SecretName,
        [hashtable]$Value
    )

    $json = $Value | ConvertTo-Json -Compress

    $existing = aws secretsmanager describe-secret `
        --secret-id $SecretName `
        --region $Region 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Secret '$SecretName' not found. Run terraform apply first."
    }

    aws secretsmanager put-secret-value `
        --secret-id $SecretName `
        --secret-string $json `
        --region $Region | Out-Null

    if ($LASTEXITCODE -ne 0) { throw "Failed to write secret '$SecretName'." }
    Write-Success "Written: $SecretName"
}

# ── Grafana admin credentials ─────────────────────────────────────────────

Write-Step "Grafana admin credentials"
Write-Info "Secret path: $ClusterName/grafana/admin"
Write-Info "Keys expected by ESO: 'username', 'password'"

$grafanaUser = Get-SecretValue `
    -Prompt    "Grafana admin username (default: admin)" `
    -EnvVarName "GRAFANA_ADMIN_USERNAME" `
    -IsPassword $false

if ([string]::IsNullOrWhiteSpace($grafanaUser)) { $grafanaUser = "admin" }

$grafanaPass = Get-SecretValue `
    -Prompt    "Grafana admin password" `
    -EnvVarName "GRAFANA_ADMIN_PASSWORD" `
    -IsPassword $true

if ([string]::IsNullOrWhiteSpace($grafanaPass)) {
    throw "Grafana admin password cannot be empty."
}

Set-Secret -SecretName "$ClusterName/grafana/admin" -Value @{
    username = $grafanaUser
    password = $grafanaPass
}

# ── Summary ───────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("-" * 60) -ForegroundColor DarkGray
Write-Host "Secret values written successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Secrets Manager paths:"
Write-Host "  $ClusterName/grafana/admin"
Write-Host ""
Write-Host "External Secrets Operator will sync these into the cluster"
Write-Host "within the next refresh cycle (up to 1 hour, or restart ESO)."
Write-Host ""
Write-Host "To force an immediate sync:"

Write-Host @"
  kubectl annotate externalsecret grafana-admin -n monitoring ""
    force-sync=$(date +%s) --overwrite
"@

Write-Host ("-" * 60) -ForegroundColor DarkGray

# ── CI usage notes ────────────────────────────────────────────────────────
# Example:
#   $env:GRAFANA_ADMIN_USERNAME = "admin"
#   $env:GRAFANA_ADMIN_PASSWORD = "your-secret"
#   pwsh ./scripts/set-secret-values.ps1 -ClusterName startup-eks