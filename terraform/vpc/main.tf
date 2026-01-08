# =============================================================================
# VPC Module for EKS
# =============================================================================
# This module creates a production-ready VPC designed for Amazon EKS clusters.
# It implements AWS best practices for network isolation and high availability.
#
# Architecture:
# - 3 Availability Zones for high availability
# - Public subnets for load balancers and NAT gateways
# - Private subnets for EKS nodes (no direct internet access)
# - NAT Gateway(s) for outbound internet from private subnets
# - Optional VPC Flow Logs for network troubleshooting
#
# Cost Optimization:
# - Use nat_gateway_mode="single" for dev (~$30/month vs ~$90 for HA)
# - Disable flow logs in dev to save CloudWatch costs
# =============================================================================

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
# The main VPC that houses all resources. DNS support is required for EKS
# to resolve internal service names and for pods to communicate.
#
# The kubernetes.io/cluster tag is REQUIRED for:
# - EKS to identify which VPC resources belong to which cluster
# - AWS Load Balancer Controller to auto-discover subnets
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true  # Required for EKS - enables DNS hostnames
  enable_dns_support   = true  # Required for EKS - enables DNS resolution

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-vpc"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"  # EKS cluster tag
    }
  )
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
# Provides internet connectivity for resources in public subnets.
# Required for ALB/NLB and NAT Gateway to function.
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-igw"
    }
  )
}

# -----------------------------------------------------------------------------
# Public Subnets
# -----------------------------------------------------------------------------
# Public subnets are used for:
# - NAT Gateways (outbound internet for private subnets)
# - Application Load Balancers (ALB) and Network Load Balancers (NLB)
# - Bastion hosts (if needed)
#
# The kubernetes.io/role/elb=1 tag tells AWS Load Balancer Controller
# to place internet-facing load balancers in these subnets.
#
# CIDR calculation: cidrsubnet("10.0.0.0/16", 8, 0) = 10.0.0.0/24
#                   cidrsubnet("10.0.0.0/16", 8, 1) = 10.0.1.0/24
#                   cidrsubnet("10.0.0.0/16", 8, 2) = 10.0.2.0/24
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)  # /24 subnets
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true  # Instances get public IPs automatically

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-public-${var.availability_zones[count.index]}"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
      "kubernetes.io/role/elb"                    = "1"  # For internet-facing LBs
    }
  )
}

# -----------------------------------------------------------------------------
# Private Subnets
# -----------------------------------------------------------------------------
# Private subnets are used for:
# - EKS worker nodes (security best practice - no direct internet exposure)
# - RDS databases
# - Internal application pods
#
# The kubernetes.io/role/internal-elb=1 tag tells AWS Load Balancer Controller
# to place internal load balancers in these subnets.
#
# CIDR calculation: cidrsubnet("10.0.0.0/16", 8, 100) = 10.0.100.0/24
#                   cidrsubnet("10.0.0.0/16", 8, 101) = 10.0.101.0/24
#                   cidrsubnet("10.0.0.0/16", 8, 102) = 10.0.102.0/24
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 100)  # /24 subnets, offset by 100
  availability_zone = var.availability_zones[count.index]

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-private-${var.availability_zones[count.index]}"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
      "kubernetes.io/role/internal-elb"           = "1"  # For internal LBs
    }
  )
}

# -----------------------------------------------------------------------------
# Elastic IPs for NAT Gateways
# -----------------------------------------------------------------------------
# Each NAT Gateway requires a static Elastic IP address.
#
# Modes:
# - "single": One NAT Gateway (cost-effective for dev, ~$30/month)
# - "ha": One NAT Gateway per AZ (production recommended, ~$90/month)
#
# Why HA mode for production?
# - If a single NAT Gateway fails, all private subnets lose internet
# - With HA mode, each AZ has its own NAT Gateway for fault isolation
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? (var.nat_gateway_mode == "single" ? 1 : length(var.availability_zones)) : 0
  domain = "vpc"

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-nat-eip-${var.availability_zones[count.index]}"
    }
  )

  depends_on = [aws_internet_gateway.main]  # IGW must exist before EIP
}

# -----------------------------------------------------------------------------
# NAT Gateways
# -----------------------------------------------------------------------------
# NAT Gateways allow resources in private subnets to access the internet
# (for pulling container images, updates, etc.) while preventing inbound
# connections from the internet.
#
# Placement: Always in PUBLIC subnets (they need internet access via IGW)
# Cost: ~$30/month per gateway + data transfer charges
# -----------------------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  count         = var.enable_nat_gateway ? (var.nat_gateway_mode == "single" ? 1 : length(var.availability_zones)) : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id  # NAT GW goes in PUBLIC subnet

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-nat-${var.availability_zones[count.index]}"
    }
  )

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# Public Route Table
# -----------------------------------------------------------------------------
# Routes all internet-bound traffic (0.0.0.0/0) through the Internet Gateway.
# All public subnets share this single route table.
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"           # All internet traffic
    gateway_id = aws_internet_gateway.main.id  # Goes through IGW
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-public-rt"
    }
  )
}

# Associate public subnets with the public route table
resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Private Route Tables
# -----------------------------------------------------------------------------
# Each private subnet gets its own route table. In HA mode, each routes
# through its AZ's NAT Gateway. In single mode, all route through one NAT.
#
# Why separate route tables?
# - Allows AZ-specific routing in HA mode
# - Provides flexibility for future network policies
# -----------------------------------------------------------------------------
resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"  # All internet traffic
    nat_gateway_id = var.enable_nat_gateway ? aws_nat_gateway.main[var.nat_gateway_mode == "single" ? 0 : count.index].id : null
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-private-rt-${var.availability_zones[count.index]}"
    }
  )
}

# Associate private subnets with their respective route tables
resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# -----------------------------------------------------------------------------
# VPC Flow Logs (Optional)
# -----------------------------------------------------------------------------
# VPC Flow Logs capture network traffic metadata for troubleshooting.
# Useful for debugging connectivity issues between pods, nodes, and services.
#
# What it captures:
# - Source/destination IPs and ports
# - Protocol and action (ACCEPT/REJECT)
# - Bytes and packets transferred
#
# Cost consideration: CloudWatch Logs charges apply (~$0.50/GB ingested)
# Recommendation: Enable for production, disable for dev to save costs
# -----------------------------------------------------------------------------
resource "aws_flow_log" "main" {
  count                    = var.enable_flow_logs ? 1 : 0
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  traffic_type             = "ALL"  # Capture ACCEPT, REJECT, and ALL traffic
  vpc_id                   = aws_vpc.main.id
  max_aggregation_interval = 60  # Aggregate logs every 60 seconds

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-flow-logs"
    }
  )
}

# CloudWatch Log Group for Flow Logs
resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/aws/vpc/${var.cluster_name}"
  retention_in_days = 7  # Keep logs for 7 days to minimize costs

  tags = var.tags
}

# IAM Role for Flow Logs to write to CloudWatch
resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${var.cluster_name}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

# IAM Policy allowing Flow Logs to write to CloudWatch
resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${var.cluster_name}-flow-logs-policy"
  role  = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}
