variable "cluster_name"          { type = string }
variable "cluster_endpoint"       { type = string }
variable "karpenter_version"      { type = string }
variable "karpenter_namespace"    { type = string }
variable "private_subnet_ids"     { type = list(string) }
variable "node_security_group_id" { type = string }
variable "aws_region"             { type = string }
variable "account_id"             { type = string }
variable "partition" {
  type    = string
  default = "aws"
}
