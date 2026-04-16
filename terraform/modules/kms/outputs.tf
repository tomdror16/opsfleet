output "eks_kms_key_arn"            { value = aws_kms_key.eks_secrets.arn }
output "eks_kms_key_id"             { value = aws_kms_key.eks_secrets.key_id }
output "secrets_manager_kms_key_arn" { value = aws_kms_key.secrets_manager.arn }
