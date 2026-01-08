# =============================================================================
# RDS Module
# =============================================================================
# This module creates an Amazon RDS PostgreSQL instance for application data.
# It implements AWS best practices for security and reliability.
#
# Security Features:
# - Private subnet placement (no public internet access)
# - Security group restricted to EKS nodes only
# - Encrypted storage at rest
# - Password stored in AWS Secrets Manager
# - Randomly generated strong password
#
# High Availability Options:
# - multi_az=true for automatic failover (recommended for production)
# - Automated backups with configurable retention
#
# Cost: db.t4g.micro ~$12/month, db.t4g.small ~$25/month
# =============================================================================

# =============================================================================
# SECURITY GROUP
# =============================================================================

# -----------------------------------------------------------------------------
# RDS Security Group
# -----------------------------------------------------------------------------
# Controls network access to the database. Only EKS nodes can connect.
# This prevents direct access from the internet or other VPC resources.
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name_prefix = "${var.cluster_name}-rds-sg"
  description = "Security group for RDS PostgreSQL - allows access from EKS only"
  vpc_id      = var.vpc_id

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-rds-sg"
    }
  )
}

# Allow PostgreSQL connections ONLY from EKS worker nodes
resource "aws_security_group_rule" "rds_ingress_from_eks" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = var.eks_node_security_group_id  # Only EKS nodes!
  security_group_id        = aws_security_group.rds.id
  description              = "Allow PostgreSQL from EKS nodes"
}

# Allow outbound traffic (needed for RDS internal operations)
resource "aws_security_group_rule" "rds_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.rds.id
  description       = "Allow all outbound"
}

# =============================================================================
# SUBNET GROUP
# =============================================================================

# -----------------------------------------------------------------------------
# DB Subnet Group
# -----------------------------------------------------------------------------
# Defines which subnets RDS can use. We use private subnets for security.
# RDS requires at least 2 subnets in different AZs for Multi-AZ deployments.
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.cluster_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids  # PRIVATE subnets only

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-db-subnet-group"
    }
  )
}

# =============================================================================
# PASSWORD GENERATION
# =============================================================================

# -----------------------------------------------------------------------------
# Random Password
# -----------------------------------------------------------------------------
# Generate a strong, random password for the database.
# This is more secure than hardcoded or user-provided passwords.
# The password is stored in Secrets Manager for secure retrieval.
# -----------------------------------------------------------------------------
resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}:?"  # Avoid characters that cause shell issues
}

# =============================================================================
# RDS INSTANCE
# =============================================================================

# -----------------------------------------------------------------------------
# PostgreSQL RDS Instance
# -----------------------------------------------------------------------------
# Managed PostgreSQL database with automated backups, patching, and monitoring.
#
# Instance Classes (for reference):
# - db.t4g.micro: 2 vCPU, 1GB RAM (~$12/month) - dev/test
# - db.t4g.small: 2 vCPU, 2GB RAM (~$25/month) - small production
# - db.t4g.medium: 2 vCPU, 4GB RAM (~$50/month) - medium production
# - db.r6g.large: 2 vCPU, 16GB RAM (~$170/month) - memory-intensive
#
# Storage Types:
# - gp3: Latest generation, consistent performance, recommended
# - gp2: Previous generation, burstable
# - io1/io2: Provisioned IOPS for high-performance needs
# -----------------------------------------------------------------------------
resource "aws_db_instance" "postgres" {
  identifier     = "${var.cluster_name}-postgres"
  engine         = "postgres"
  engine_version = var.postgres_version  # e.g., "15.4"

  # Compute and Storage
  instance_class    = var.db_instance_class     # e.g., "db.t4g.micro"
  allocated_storage = var.db_allocated_storage  # Initial size in GB
  storage_type      = "gp3"                     # Latest generation SSD
  storage_encrypted = true                      # SECURITY: Always encrypt!

  # Database Configuration
  db_name  = var.db_name    # Initial database name
  username = var.db_username
  password = random_password.db_password.result  # Generated password

  # Network Configuration
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false  # SECURITY: No public access!

  # Backup Configuration
  # Automated backups allow point-in-time recovery
  backup_retention_period = var.backup_retention_period  # Days to keep backups
  backup_window           = "03:00-04:00"                # UTC, low-traffic time
  maintenance_window      = "mon:04:00-mon:05:00"        # After backup window

  # High Availability
  # Multi-AZ creates a standby replica for automatic failover
  multi_az = var.multi_az  # true for production

  # Snapshot Configuration
  # Skip final snapshot in dev to allow quick destruction
  skip_final_snapshot       = var.environment == "dev" ? true : false
  final_snapshot_identifier = var.environment == "dev" ? null : "${var.cluster_name}-final-snapshot"

  # Monitoring
  # CloudWatch logs for debugging connection and query issues
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = false  # Enable for production debugging

  # Protection
  # Prevent accidental deletion in production
  deletion_protection = var.environment == "prod" ? true : false

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-postgres"
    }
  )
}

# =============================================================================
# SECRETS MANAGER
# =============================================================================

# -----------------------------------------------------------------------------
# Database Credentials Secret
# -----------------------------------------------------------------------------
# Store database credentials securely in AWS Secrets Manager.
# Applications retrieve credentials at runtime using IRSA.
#
# Benefits over hardcoded credentials:
# - Centralized credential management
# - Automatic rotation (can be configured)
# - Audit trail of secret access
# - No credentials in code or environment variables
#
# Usage from pods:
# 1. Create IAM role with secretsmanager:GetSecretValue permission
# 2. Associate role with Kubernetes service account (IRSA)
# 3. Use External Secrets Operator or AWS SDK to fetch secrets
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db_password" {
  name_prefix             = "${var.cluster_name}-db-password-"
  description             = "Database credentials for ${var.cluster_name} PostgreSQL"
  # In dev, allow immediate deletion. In prod, require 7-day recovery period.
  recovery_window_in_days = var.environment == "dev" ? 0 : 7

  tags = var.tags
}

# Store the actual secret value as JSON for easy parsing
resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.postgres.address  # RDS endpoint
    port     = aws_db_instance.postgres.port
    dbname   = var.db_name
    engine   = "postgres"
  })
}
