# =============================================================================
# EKS Module
# =============================================================================
# This module creates an Amazon EKS cluster with managed node groups.
# It implements AWS best practices for security, networking, and operations.
#
# Components created:
# - EKS Control Plane (managed by AWS)
# - Managed Node Group (EC2 instances for running pods)
# - IAM Roles and Policies (cluster, nodes, and IRSA)
# - Security Groups (network isolation)
# - EKS Add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI)
# - OIDC Provider (for IAM Roles for Service Accounts)
#
# Security Features:
# - Private nodes (no public IP addresses)
# - IMDSv2 required (prevents SSRF attacks)
# - Encrypted EBS volumes
# - IRSA enabled (fine-grained pod-level IAM)
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------
# These data sources fetch information about the current AWS account and
# partition (aws, aws-gov, aws-cn) for constructing ARNs dynamically.
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# =============================================================================
# CLUSTER IAM CONFIGURATION
# =============================================================================

# -----------------------------------------------------------------------------
# EKS Cluster IAM Role
# -----------------------------------------------------------------------------
# The EKS service needs an IAM role to manage AWS resources on your behalf.
# This includes creating ENIs for pod networking, managing load balancers, etc.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  # Trust policy: Only EKS service can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

# Attach AWS-managed policies required for EKS cluster operation
resource "aws_iam_role_policy_attachment" "cluster_policy" {
  # Core EKS permissions: create/manage ENIs, describe EC2 resources
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_vpc_resource_controller" {
  # Required for security groups for pods feature
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

# =============================================================================
# CLUSTER SECURITY GROUP
# =============================================================================

# -----------------------------------------------------------------------------
# EKS Cluster Security Group
# -----------------------------------------------------------------------------
# Controls network access to the EKS API server.
# The cluster SG is attached to the ENIs that the control plane uses.
# -----------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name_prefix = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster security group - controls access to K8s API"
  vpc_id      = var.vpc_id

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-cluster-sg"
    }
  )
}

# Allow cluster to communicate outbound (for AWS API calls, etc.)
resource "aws_security_group_rule" "cluster_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"  # All protocols
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
}

# =============================================================================
# CLOUDWATCH LOGGING
# =============================================================================

# -----------------------------------------------------------------------------
# Control Plane Logs
# -----------------------------------------------------------------------------
# EKS can send control plane logs to CloudWatch for debugging and auditing.
# Log types:
# - api: Kubernetes API server logs
# - audit: Kubernetes audit logs (who did what)
# - authenticator: IAM authenticator logs
# - controllerManager: Controller manager logs
# - scheduler: Scheduler logs
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 7  # Adjust based on compliance requirements

  tags = var.tags
}

# =============================================================================
# EKS CLUSTER
# =============================================================================

# -----------------------------------------------------------------------------
# EKS Cluster Resource
# -----------------------------------------------------------------------------
# The main EKS cluster. AWS manages the control plane (API server, etcd, etc.)
# We configure networking, logging, and access settings.
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    # Subnets where EKS can place ENIs for API server communication
    # Include both private (for nodes) and public (for load balancers)
    subnet_ids = concat(var.private_subnet_ids, var.public_subnet_ids)

    # API Server Endpoint Access:
    # - endpoint_private_access: Allows kubectl from within VPC
    # - endpoint_public_access: Allows kubectl from internet (restricted by CIDR)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs  # Restrict who can access API

    security_group_ids = [aws_security_group.cluster.id]
  }

  # Enable all control plane log types for debugging
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_vpc_resource_controller,
    aws_cloudwatch_log_group.cluster
  ]

  tags = var.tags
}

# =============================================================================
# OIDC PROVIDER (IRSA)
# =============================================================================

# -----------------------------------------------------------------------------
# OIDC Provider for IAM Roles for Service Accounts (IRSA)
# -----------------------------------------------------------------------------
# IRSA allows Kubernetes service accounts to assume IAM roles.
# This is the RECOMMENDED way to grant AWS permissions to pods.
#
# Benefits over instance roles:
# - Fine-grained: Each pod can have different permissions
# - Secure: Pods only get the permissions they need
# - Auditable: IAM logs show which service account made AWS calls
#
# Example use cases:
# - Pod accessing S3 bucket
# - Pod reading secrets from Secrets Manager
# - Pod writing metrics to CloudWatch
# -----------------------------------------------------------------------------
data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-irsa"
    }
  )
}

# =============================================================================
# NODE IAM CONFIGURATION
# =============================================================================

# -----------------------------------------------------------------------------
# Node IAM Role
# -----------------------------------------------------------------------------
# IAM role that EC2 instances (nodes) assume. Nodes need permissions to:
# - Register with EKS cluster
# - Pull container images from ECR
# - Attach/detach ENIs for pod networking
# -----------------------------------------------------------------------------
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

# Required policies for EKS worker nodes
resource "aws_iam_role_policy_attachment" "node_policy" {
  # Core node permissions: describe cluster, register node
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  # VPC CNI permissions: manage ENIs for pod networking
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_registry_policy" {
  # ECR permissions: pull container images
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

# =============================================================================
# NODE SECURITY GROUP
# =============================================================================

# -----------------------------------------------------------------------------
# Node Security Group
# -----------------------------------------------------------------------------
# Controls network access to/from worker nodes.
# Nodes need to communicate with:
# - Each other (for pod-to-pod traffic)
# - The EKS control plane (for kubectl exec, logs, etc.)
# - Internet (via NAT Gateway for pulling images)
# -----------------------------------------------------------------------------
resource "aws_security_group" "node" {
  name_prefix = "${var.cluster_name}-node-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-node-sg"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  )
}

# Allow nodes to communicate with each other (pod-to-pod traffic)
resource "aws_security_group_rule" "node_ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"  # All protocols
  self              = true  # Same security group
  security_group_id = aws_security_group.node.id
}

# Allow control plane to communicate with nodes (for kubectl exec/logs)
resource "aws_security_group_rule" "node_ingress_cluster" {
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id  # From control plane
  security_group_id        = aws_security_group.node.id
}

# Allow nodes to communicate with control plane (HTTPS to API server)
resource "aws_security_group_rule" "cluster_ingress_node_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id  # From nodes
  security_group_id        = aws_security_group.cluster.id
}

# Allow all outbound from nodes (for pulling images, AWS API calls, etc.)
resource "aws_security_group_rule" "node_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node.id
}

# =============================================================================
# MANAGED NODE GROUP
# =============================================================================

# -----------------------------------------------------------------------------
# EKS Managed Node Group
# -----------------------------------------------------------------------------
# AWS-managed EC2 instances for running pods. AWS handles:
# - AMI updates and patching
# - Node draining during updates
# - Auto-replacement of unhealthy nodes
#
# Scaling:
# - desired_size: Initial number of nodes
# - min_size: Minimum nodes (for Cluster Autoscaler)
# - max_size: Maximum nodes (cost protection)
#
# Capacity Types:
# - ON_DEMAND: Reliable, higher cost
# - SPOT: Up to 90% cheaper, but can be interrupted
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-node-group"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids  # Nodes in PRIVATE subnets only

  scaling_config {
    desired_size = var.node_group_desired_size
    max_size     = var.node_group_max_size
    min_size     = var.node_group_min_size
  }

  update_config {
    max_unavailable = 1  # Rolling update: 1 node at a time
  }

  instance_types = var.node_instance_types  # e.g., ["t3.medium"]
  capacity_type  = var.node_capacity_type   # ON_DEMAND or SPOT

  # Use launch template for additional configuration
  launch_template {
    id      = aws_launch_template.node.id
    version = "$Latest"
  }

  labels = var.node_labels  # Kubernetes labels for node selection

  depends_on = [
    aws_iam_role_policy_attachment.node_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_registry_policy
  ]

  tags = var.tags

  lifecycle {
    create_before_destroy = true
    # Ignore desired_size changes from Cluster Autoscaler
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# -----------------------------------------------------------------------------
# Launch Template for Node Group
# -----------------------------------------------------------------------------
# Provides additional configuration for EC2 instances that can't be set
# directly on the node group (disk encryption, IMDSv2, etc.)
# -----------------------------------------------------------------------------
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"
  description = "Launch template for EKS managed node group"

  # EBS Volume Configuration
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"          # Latest generation, better performance
      iops                  = 3000           # gp3 baseline IOPS
      delete_on_termination = true
      encrypted             = true           # SECURITY: Always encrypt EBS
    }
  }

  # Instance Metadata Service (IMDS) Configuration
  # IMDSv2 is required for security - prevents SSRF attacks
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # SECURITY: IMDSv2 required
    http_put_response_hop_limit = 1           # Limit to prevent container escapes
  }

  # Network Configuration
  network_interfaces {
    associate_public_ip_address = false  # SECURITY: Nodes in private subnets
    delete_on_termination       = true
    security_groups             = [aws_security_group.node.id]
  }

  # Instance Tags
  tag_specifications {
    resource_type = "instance"
    tags = merge(
      var.tags,
      {
        Name = "${var.cluster_name}-node"
      }
    )
  }

  tags = var.tags
}

# =============================================================================
# EKS ADD-ONS
# =============================================================================
# EKS Add-ons are AWS-managed Kubernetes components that extend cluster
# functionality. AWS handles updates and ensures compatibility.
# =============================================================================

# -----------------------------------------------------------------------------
# VPC CNI Add-on
# -----------------------------------------------------------------------------
# The Amazon VPC CNI provides native VPC networking for pods.
# Each pod gets an IP from the VPC CIDR, enabling direct communication.
# This is what makes AWS networking "just work" in EKS.
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
  # Let AWS auto-select compatible version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"  # Don't overwrite custom configs
  tags                        = var.tags
}

# -----------------------------------------------------------------------------
# kube-proxy Add-on
# -----------------------------------------------------------------------------
# kube-proxy maintains network rules on nodes for Service connectivity.
# It enables pods to communicate with Services via cluster IPs.
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = var.tags
}

# -----------------------------------------------------------------------------
# CoreDNS Add-on
# -----------------------------------------------------------------------------
# CoreDNS provides DNS-based service discovery in the cluster.
# Pods use it to resolve service names (e.g., my-service.default.svc.cluster.local)
#
# IMPORTANT: CoreDNS pods run on nodes, so this must wait for node group
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_eks_node_group.main]  # Needs nodes!
  tags                        = var.tags
}

# -----------------------------------------------------------------------------
# EBS CSI Driver Add-on
# -----------------------------------------------------------------------------
# The EBS CSI Driver enables Kubernetes to provision EBS volumes for pods.
# Required for PersistentVolumeClaims with gp2/gp3 storage classes.
#
# Uses IRSA: The driver assumes an IAM role to create/attach EBS volumes.
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"
  # Uses IRSA for AWS API access
  service_account_role_arn    = aws_iam_role.ebs_csi_driver.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.main]  # Needs nodes!

  tags = var.tags
}

# IAM Role for EBS CSI Driver (IRSA)
resource "aws_iam_role" "ebs_csi_driver" {
  name = "${var.cluster_name}-ebs-csi-driver"

  # Trust policy: Only the EBS CSI controller service account can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.cluster.arn
      }
      Condition = {
        StringEquals = {
          # Only this specific service account can assume the role
          "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

# Attach AWS-managed policy for EBS CSI Driver
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}
