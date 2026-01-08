# =============================================================================
# EKS TODO GitOps - Root Terraform Module
# =============================================================================
# This is the main entry point for the Terraform configuration.
# It orchestrates all the infrastructure modules and sets up providers.
#
# Modules:
# - VPC: Networking foundation (subnets, NAT gateways, routing)
# - EKS: Kubernetes cluster and node groups
# - ECR: Container image registry
# - RDS: PostgreSQL database
#
# Providers:
# - AWS: For all AWS resources
# - Kubernetes: For in-cluster resources (namespaces)
# - Helm: For Helm chart deployments (future use)
#
# Usage:
#   cd terraform
#   terraform init
#   terraform plan -var-file=environments/dev.tfvars
#   terraform apply -var-file=environments/dev.tfvars
# =============================================================================

# -----------------------------------------------------------------------------
# AWS Provider Configuration
# -----------------------------------------------------------------------------
# Configures the AWS provider with default tags applied to all resources.
# This ensures consistent tagging for cost allocation and resource management.
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  # Default tags applied to ALL resources created by this configuration
  # Individual resources can add additional tags or override these
  default_tags {
    tags = {
      Project     = "eks-todo-gitops"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------
# Fetch dynamic information about the AWS environment
# -----------------------------------------------------------------------------

# Get available AZs in the region (filters out Local Zones, Wavelength, etc.)
data "aws_availability_zones" "available" {
  state = "available"
}

# -----------------------------------------------------------------------------
# Local Values
# -----------------------------------------------------------------------------
# Computed values used throughout the configuration
# -----------------------------------------------------------------------------
locals {
  # Cluster name follows pattern: <project>-<environment>
  # Example: eks-todo-gitops-dev
  cluster_name = "${var.project_name}-${var.environment}"

  # Use first 3 availability zones for high availability
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Common tags for all modules (in addition to provider default_tags)
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

# =============================================================================
# INFRASTRUCTURE MODULES
# =============================================================================

# -----------------------------------------------------------------------------
# VPC Module
# -----------------------------------------------------------------------------
# Creates the network foundation for EKS:
# - VPC with DNS support
# - Public subnets (for load balancers, NAT gateways)
# - Private subnets (for EKS nodes, RDS)
# - NAT Gateway(s) for outbound internet access
# - Route tables and associations
# -----------------------------------------------------------------------------
module "vpc" {
  source = "./vpc"

  cluster_name       = local.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = local.azs
  enable_nat_gateway = var.enable_nat_gateway
  nat_gateway_mode   = var.nat_gateway_mode    # "single" for dev, "ha" for prod
  enable_flow_logs   = var.enable_flow_logs

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# EKS Module
# -----------------------------------------------------------------------------
# Creates the Kubernetes cluster:
# - EKS control plane (managed by AWS)
# - Managed node group (EC2 instances)
# - IAM roles for cluster and nodes
# - OIDC provider for IRSA
# - EKS add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI)
# -----------------------------------------------------------------------------
module "eks" {
  source = "./eks"

  cluster_name       = local.cluster_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  kubernetes_version                   = var.kubernetes_version
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Node group configuration
  node_instance_types     = var.node_instance_types
  node_capacity_type      = var.node_capacity_type  # ON_DEMAND or SPOT
  node_disk_size          = var.node_disk_size
  node_group_desired_size = var.node_group_desired_size
  node_group_min_size     = var.node_group_min_size
  node_group_max_size     = var.node_group_max_size

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# ECR Module
# -----------------------------------------------------------------------------
# Creates container registry for application images:
# - ECR repository with image scanning
# - Lifecycle policy to limit stored images
# -----------------------------------------------------------------------------
module "ecr" {
  source = "./ecr"

  cluster_name = local.cluster_name
  tags         = local.common_tags
}

# -----------------------------------------------------------------------------
# RDS Module
# -----------------------------------------------------------------------------
# Creates PostgreSQL database for application data:
# - RDS instance in private subnets
# - Security group allowing access from EKS only
# - Credentials stored in Secrets Manager
# -----------------------------------------------------------------------------
module "rds" {
  source = "./rds"

  cluster_name               = local.cluster_name
  environment                = var.environment
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id

  # Database configuration
  db_instance_class       = "db.t4g.micro"  # Smallest instance for dev
  db_allocated_storage    = 20              # GB
  backup_retention_period = 7               # Days
  multi_az                = false           # Set true for production!

  tags = local.common_tags
}

# =============================================================================
# KUBERNETES CONFIGURATION
# =============================================================================

# -----------------------------------------------------------------------------
# Update kubeconfig
# -----------------------------------------------------------------------------
# Automatically configure kubectl to connect to the new cluster.
# Creates a kubeconfig file in the terraform directory.
# -----------------------------------------------------------------------------
resource "null_resource" "update_kubeconfig" {
  depends_on = [module.eks]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.aws_region} --name ${local.cluster_name} --kubeconfig ${path.root}/kubeconfig"
  }

  # Re-run if cluster endpoint changes (indicates cluster recreation)
  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
  }
}

# -----------------------------------------------------------------------------
# Kubernetes Provider
# -----------------------------------------------------------------------------
# Configures Terraform to manage Kubernetes resources.
# Uses AWS IAM for authentication via the aws eks get-token command.
# -----------------------------------------------------------------------------
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  # Use AWS IAM authentication
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name,
      "--region",
      var.aws_region
    ]
  }
}

# -----------------------------------------------------------------------------
# Helm Provider
# -----------------------------------------------------------------------------
# Configures Terraform to deploy Helm charts.
# Uses same authentication as Kubernetes provider.
# -----------------------------------------------------------------------------
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        module.eks.cluster_name,
        "--region",
        var.aws_region
      ]
    }
  }
}

# =============================================================================
# KUBERNETES NAMESPACES
# =============================================================================
# Pre-create namespaces for organizing workloads.
# This ensures namespaces exist before Helm/kubectl deployments.
# =============================================================================

# Namespace for application workloads (TODO API, etc.)
resource "kubernetes_namespace" "apps" {
  depends_on = [module.eks]

  metadata {
    name = "apps"
    labels = {
      name        = "apps"
      environment = var.environment
    }
  }
}

# Namespace for monitoring stack (Prometheus, Grafana)
resource "kubernetes_namespace" "monitoring" {
  depends_on = [module.eks]

  metadata {
    name = "monitoring"
    labels = {
      name        = "monitoring"
      environment = var.environment
    }
  }
}

# Namespace for platform services (ArgoCD, External Secrets, etc.)
resource "kubernetes_namespace" "platform" {
  depends_on = [module.eks]

  metadata {
    name = "platform"
    labels = {
      name        = "platform"
      environment = var.environment
    }
  }
}
