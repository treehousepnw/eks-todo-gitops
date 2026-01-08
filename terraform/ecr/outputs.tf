output "repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.todo_api.repository_url
}

output "repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.todo_api.name
}

output "repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.todo_api.arn
}