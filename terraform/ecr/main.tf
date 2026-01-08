# =============================================================================
# ECR Module
# =============================================================================
# This module creates an Amazon Elastic Container Registry (ECR) repository
# for storing Docker images used by the TODO API application.
#
# Features:
# - Image scanning on push (vulnerability detection)
# - Encryption at rest
# - Lifecycle policy to limit storage costs
#
# Usage:
# 1. Build your Docker image: docker build -t todo-api .
# 2. Tag for ECR: docker tag todo-api:latest <account>.dkr.ecr.<region>.amazonaws.com/<repo>:latest
# 3. Login to ECR: aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
# 4. Push image: docker push <account>.dkr.ecr.<region>.amazonaws.com/<repo>:latest
#
# Cost: ~$0.10/GB/month for storage, first 500MB free
# =============================================================================

# -----------------------------------------------------------------------------
# ECR Repository
# -----------------------------------------------------------------------------
# Container image repository for the TODO API.
#
# Image Tag Mutability:
# - MUTABLE: Tags can be overwritten (convenient for :latest)
# - IMMUTABLE: Tags cannot be changed (recommended for production)
#
# Recommendation: Use MUTABLE for dev (easy iteration), IMMUTABLE for prod
# (ensures deployed image can't change unexpectedly)
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "todo_api" {
  name                 = "${var.cluster_name}-todo-api"
  image_tag_mutability = "MUTABLE"  # Allow overwriting tags like :latest

  # Security: Scan images for vulnerabilities when pushed
  # Findings appear in ECR console and can trigger alerts
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encryption at rest using AWS-managed keys
  # Use KMS for customer-managed keys if required by compliance
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# ECR Lifecycle Policy
# -----------------------------------------------------------------------------
# Automatically clean up old images to control storage costs.
# This policy keeps only the 5 most recent images.
#
# Lifecycle rules are evaluated in priority order (lower number = higher priority)
# Common patterns:
# - Keep last N images
# - Delete images older than X days
# - Keep tagged images, expire untagged
#
# Adjust based on your deployment frequency and rollback needs
# -----------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "todo_api" {
  repository = aws_ecr_repository.todo_api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images - prevents unbounded storage growth"
      selection = {
        tagStatus     = "any"              # Apply to all images (tagged and untagged)
        countType     = "imageCountMoreThan"
        countNumber   = 5                  # Keep only 5 images
      }
      action = {
        type = "expire"  # Delete images matching this rule
      }
    }]
  })
}
