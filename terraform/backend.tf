# ─────────────────────────────────────────────────────────────────────────────
# Remote State Backend
#
# BEFORE running terraform init for the first time:
#
#   1. Create the S3 bucket (versioning + encryption enabled):
#        aws s3api create-bucket \
#          --bucket <YOUR_BUCKET_NAME> \
#          --region eu-west-1 \
#          --create-bucket-configuration LocationConstraint=eu-west-1
#
#        aws s3api put-bucket-versioning \
#          --bucket <YOUR_BUCKET_NAME> \
#          --versioning-configuration Status=Enabled
#
#        aws s3api put-bucket-encryption \
#          --bucket <YOUR_BUCKET_NAME> \
#          --server-side-encryption-configuration \
#          '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#   4. Run: terraform init
#
# The bootstrap script at scripts/bootstrap-state-backend.sh automates steps 1-2.
# ─────────────────────────────────────────────────────────────────────────────

#terraform {
  #backend "s3" {
  #  bucket         = "REPLACE_WITH_YOUR_STATE_BUCKET"   # e.g. mycompany-terraform-state
  #  key            = "startup-eks/terraform.tfstate"
  #  region         = "eu-west-1"
  #  encrypt        = true
  #  use_lockfile = true
  #}
#}
terraform {
  backend "local" {}
}