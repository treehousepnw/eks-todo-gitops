# Development Environment Configuration
environment = "dev"
owner       = "devops"

# VPC Configuration
vpc_cidr           = "10.0.0.0/16"
enable_nat_gateway = true  # 3 NAT Gateways for full HA ($108/month)
enable_flow_logs   = false # Disable for dev to reduce costs

# EKS Configuration
kubernetes_version = "1.31"

# Node Group Configuration  
node_instance_types     = ["t3.medium"] # 2 vCPU, 4GB RAM
node_capacity_type      = "ON_DEMAND"   # Change to "SPOT" for 70% savings (easy toggle!)
node_disk_size          = 20
node_group_desired_size = 2
node_group_min_size     = 1
node_group_max_size     = 4

# Access Configuration
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"] # TODO: Restrict to your IP for better security