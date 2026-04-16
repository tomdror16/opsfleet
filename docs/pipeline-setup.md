# Pipeline Setup Guide

This document explains what you need to do **once** before the GitHub Actions
pipeline can run against your AWS account.

---

## 1. Bootstrap the Terraform state backend

```powershell
cd terraform
./scripts/bootstrap-state-backend.ps1 `
  -BucketName "mycompany-terraform-state" `
  -Region "eu-west-1"
```

This creates the S3 bucket + DynamoDB lock table and patches `backend.tf` with
the bucket name. Commit `backend.tf` after running this.

---

## 2. Create an AWS OIDC identity provider for GitHub Actions

This allows GitHub Actions to assume an IAM role **without storing any
long-lived AWS credentials** in GitHub Secrets.

```powershell
# Create the OIDC provider (only needed once per AWS account)
aws iam create-open-id-connect-provider `
  --url "https://token.actions.githubusercontent.com" `
  --client-id-list "sts.amazonaws.com" `
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
```

---

## 3. Create the IAM role for GitHub Actions

Replace `YOUR_GITHUB_ORG` and `YOUR_REPO_NAME` with your actual values.

```powershell
$TrustPolicy = @{
  Version   = "2012-10-17"
  Statement = @(
    @{
      Effect    = "Allow"
      Principal = @{ Federated = "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):oidc-provider/token.actions.githubusercontent.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = @{
        StringEquals = @{
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = @{
          # Allows any branch/PR in your repo to assume this role.
          # Tighten to `repo:YOUR_GITHUB_ORG/YOUR_REPO_NAME:ref:refs/heads/main`
          # for apply-only access from main.
          "token.actions.githubusercontent.com:sub" = "repo:YOUR_GITHUB_ORG/YOUR_REPO_NAME:*"
        }
      }
    }
  )
} | ConvertTo-Json -Depth 10 -Compress

aws iam create-role `
  --role-name "github-actions-terraform" `
  --assume-role-policy-document $TrustPolicy `
  --description "Role assumed by GitHub Actions for Terraform operations"

# Attach a policy broad enough to manage EKS, VPC, IAM, SQS, EBS, etc.
# For production, scope this down to the minimum required permissions.
aws iam attach-role-policy `
  --role-name "github-actions-terraform" `
  --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
```

> **Security note:** `AdministratorAccess` is fine for a POC. Before going to
> production, replace it with a custom policy scoped to exactly the services
> Terraform needs (EKS, EC2, IAM, VPC, SQS, EventBridge, EBS, DynamoDB, S3).

---

## 4. Add GitHub repository secrets

Go to **Settings → Secrets and variables → Actions** in your GitHub repo and
add the following secrets:

| Secret name | Value |
|---|---|
| `AWS_OIDC_ROLE_ARN` | ARN of the role created in step 3, e.g. `arn:aws:iam::123456789012:role/github-actions-terraform` |
| `GRAFANA_ADMIN_PASSWORD` | A strong password for the Grafana admin user |

---

## 5. Configure branch protection (recommended)

In **Settings → Branches**, add a protection rule for `main`:

- ✅ Require a pull request before merging
- ✅ Require status checks to pass: `Validate`, `Plan`
- ✅ Require branches to be up to date before merging
- ✅ Do not allow bypassing the above settings

---

## 6. Configure the `production` environment (for apply approval)

Go to **Settings → Environments → New environment**, name it `production`, and
add **Required reviewers**. The Apply and Destroy jobs reference this
environment, so they will pause for a manual approval before running.

---

## Pipeline behaviour summary

| Event | Jobs that run |
|---|---|
| Push to any branch (non-main) | — (no Terraform paths changed) |
| Pull request → main | Validate → Plan (result posted as PR comment) |
| Merge to main | Validate → Apply (with `production` approval gate) |
| Manual dispatch: `plan` | Validate → Plan |
| Manual dispatch: `apply` | Validate → Apply (with approval) |
| Manual dispatch: `destroy` | Validate → Destroy (with approval) |

---

## Local validation (before pushing)

```powershell
cd terraform

# Format all files in-place
terraform fmt -recursive

# Init without backend (for local validation only)
terraform init -backend=false

# Validate
terraform validate

# Lint
tflint --recursive

# Security scan (requires trivy installed: https://aquasecurity.github.io/trivy)
trivy config .
```
