variable "cluster_name" {
  description = "Name of the EKS cluster (used for ECR naming)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}