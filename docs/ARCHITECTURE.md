# Architecture Documentation

This document explains the architecture decisions and design patterns used in the EKS TODO GitOps project.

## Table of Contents

- [Overview](#overview)
- [Infrastructure Architecture](#infrastructure-architecture)
- [Network Design](#network-design)
- [Security Architecture](#security-architecture)
- [Application Architecture](#application-architecture)
- [GitOps Workflow](#gitops-workflow)
- [Design Decisions](#design-decisions)
- [Cost Considerations](#cost-considerations)

## Overview

This project demonstrates a production-grade Kubernetes deployment on AWS EKS. It follows cloud-native best practices for security, scalability, and observability.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           ARCHITECTURE OVERVIEW                          │
└─────────────────────────────────────────────────────────────────────────┘

                    ┌──────────────────┐
                    │    Developer     │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │      GitHub      │
                    │  (Source Code)   │
                    └────────┬─────────┘
                             │
           ┌─────────────────┼─────────────────┐
           │                 │                 │
           ▼                 ▼                 ▼
    ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
    │  Terraform  │  │   ArgoCD    │  │   CI/CD     │
    │   (IaC)     │  │  (GitOps)   │  │  Pipeline   │
    └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
           │                │                 │
           └────────────────┼─────────────────┘
                            │
                   ┌────────▼────────┐
                   │   AWS Cloud     │
                   │                 │
                   │  ┌───────────┐  │
                   │  │    EKS    │  │
                   │  │  Cluster  │  │
                   │  └─────┬─────┘  │
                   │        │        │
                   │  ┌─────▼─────┐  │
                   │  │  TODO API │  │
                   │  │   Pods    │  │
                   │  └─────┬─────┘  │
                   │        │        │
                   │  ┌─────▼─────┐  │
                   │  │    RDS    │  │
                   │  │ PostgreSQL│  │
                   │  └───────────┘  │
                   │                 │
                   └─────────────────┘
```

## Infrastructure Architecture

### AWS Resources

| Component | Service | Purpose |
|-----------|---------|---------|
| Networking | VPC | Isolated network for all resources |
| Compute | EKS | Managed Kubernetes control plane |
| Nodes | EC2 (Managed Node Group) | Worker nodes for running pods |
| Database | RDS PostgreSQL | Persistent data storage |
| Registry | ECR | Container image storage |
| Secrets | Secrets Manager | Secure credential storage |
| IAM | IAM + OIDC | Identity and access management |

### VPC Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        VPC (10.0.0.0/16)                                  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                    Availability Zone A                               │ │
│  │  ┌───────────────────┐       ┌───────────────────┐                  │ │
│  │  │ Public Subnet     │       │ Private Subnet     │                  │ │
│  │  │ 10.0.0.0/24       │       │ 10.0.100.0/24      │                  │ │
│  │  │                   │       │                    │                  │ │
│  │  │ • NAT Gateway     │──────▶│ • EKS Nodes        │                  │ │
│  │  │ • ALB             │       │ • RDS (primary)    │                  │ │
│  │  └───────────────────┘       └───────────────────┘                  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                    Availability Zone B                               │ │
│  │  ┌───────────────────┐       ┌───────────────────┐                  │ │
│  │  │ Public Subnet     │       │ Private Subnet     │                  │ │
│  │  │ 10.0.1.0/24       │       │ 10.0.101.0/24      │                  │ │
│  │  │                   │       │                    │                  │ │
│  │  │ • NAT Gateway*    │──────▶│ • EKS Nodes        │                  │ │
│  │  │ • ALB             │       │ • RDS (standby)*   │                  │ │
│  │  └───────────────────┘       └───────────────────┘                  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                    Availability Zone C                               │ │
│  │  ┌───────────────────┐       ┌───────────────────┐                  │ │
│  │  │ Public Subnet     │       │ Private Subnet     │                  │ │
│  │  │ 10.0.2.0/24       │       │ 10.0.102.0/24      │                  │ │
│  │  │                   │       │                    │                  │ │
│  │  │ • NAT Gateway*    │──────▶│ • EKS Nodes        │                  │ │
│  │  │ • ALB             │       │                    │                  │ │
│  │  └───────────────────┘       └───────────────────┘                  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│  * HA mode only (nat_gateway_mode = "ha")                                │
│  * Multi-AZ RDS (multi_az = true)                                        │
└──────────────────────────────────────────────────────────────────────────┘
```

### EKS Cluster Design

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           EKS CLUSTER                                    │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    Control Plane (AWS Managed)                      │ │
│  │  • Kubernetes API Server                                            │ │
│  │  • etcd (cluster state)                                             │ │
│  │  • Controller Manager                                               │ │
│  │  • Scheduler                                                        │ │
│  │  • Cloud Controller                                                 │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                              │                                           │
│                              │ HTTPS (443)                               │
│                              ▼                                           │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    Data Plane (Customer Managed)                    │ │
│  │                                                                      │ │
│  │  ┌──────────────────────────────────────────────────────────────┐  │ │
│  │  │                   Managed Node Group                          │  │ │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐           │  │ │
│  │  │  │   Node 1    │  │   Node 2    │  │   Node N    │           │  │ │
│  │  │  │ t3.medium   │  │ t3.medium   │  │ t3.medium   │           │  │ │
│  │  │  │             │  │             │  │             │           │  │ │
│  │  │  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │           │  │ │
│  │  │  │ │ kubelet │ │  │ │ kubelet │ │  │ │ kubelet │ │           │  │ │
│  │  │  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │           │  │ │
│  │  │  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │           │  │ │
│  │  │  │ │ VPC CNI │ │  │ │ VPC CNI │ │  │ │ VPC CNI │ │           │  │ │
│  │  │  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │           │  │ │
│  │  │  └─────────────┘  └─────────────┘  └─────────────┘           │  │ │
│  │  └──────────────────────────────────────────────────────────────┘  │ │
│  │                                                                      │ │
│  │  Add-ons:                                                            │ │
│  │  • vpc-cni (pod networking)                                          │ │
│  │  • coredns (service discovery)                                       │ │
│  │  • kube-proxy (service routing)                                      │ │
│  │  • aws-ebs-csi-driver (persistent volumes)                           │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

## Network Design

### Traffic Flow

```
                              Internet
                                  │
                                  ▼
                        ┌─────────────────┐
                        │ Internet Gateway│
                        └────────┬────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
        ▼                        ▼                        ▼
┌───────────────┐      ┌─────────────────┐      ┌───────────────┐
│ Public Subnet │      │  Public Subnet  │      │ Public Subnet │
│    (AZ-A)     │      │     (AZ-B)      │      │    (AZ-C)     │
│               │      │                 │      │               │
│  ┌─────────┐  │      │   ┌─────────┐   │      │  ┌─────────┐  │
│  │   NAT   │  │      │   │   ALB   │   │      │  │   NAT   │  │
│  │ Gateway │  │      │   │         │   │      │  │ Gateway │  │
│  └────┬────┘  │      │   └────┬────┘   │      │  └────┬────┘  │
└───────┼───────┘      └────────┼────────┘      └───────┼───────┘
        │                       │                       │
        │                       │                       │
        ▼                       ▼                       ▼
┌───────────────┐      ┌─────────────────┐      ┌───────────────┐
│Private Subnet │      │ Private Subnet  │      │Private Subnet │
│    (AZ-A)     │      │     (AZ-B)      │      │    (AZ-C)     │
│               │      │                 │      │               │
│  ┌─────────┐  │      │   ┌─────────┐   │      │  ┌─────────┐  │
│  │EKS Node │◀─┼──────┼───│EKS Node │───┼──────┼─▶│EKS Node │  │
│  │         │  │      │   │         │   │      │  │         │  │
│  │┌───────┐│  │      │   │┌───────┐│   │      │  │┌───────┐│  │
│  ││  Pod  ││  │      │   ││  Pod  ││   │      │  ││  Pod  ││  │
│  │└───────┘│  │      │   │└───────┘│   │      │  │└───────┘│  │
│  └─────────┘  │      │   └─────────┘   │      │  └─────────┘  │
│               │      │                 │      │               │
│  ┌─────────┐  │      │                 │      │               │
│  │   RDS   │  │      │                 │      │               │
│  │ Primary │  │      │                 │      │               │
│  └─────────┘  │      │                 │      │               │
└───────────────┘      └─────────────────┘      └───────────────┘
```

### Key Networking Decisions

1. **Private Nodes**: Worker nodes don't have public IPs, reducing attack surface
2. **NAT Gateway**: Allows outbound internet (for pulling images) without inbound
3. **VPC CNI**: Each pod gets a VPC IP, enabling native AWS networking
4. **Security Groups**: Network-level isolation between components

## Security Architecture

### IAM and IRSA

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    IAM Roles for Service Accounts (IRSA)                 │
│                                                                          │
│  Traditional (Instance Role)          IRSA (Recommended)                 │
│  ─────────────────────────────        ──────────────────────────────     │
│                                                                          │
│  ┌─────────────────────────┐          ┌─────────────────────────────┐   │
│  │      EC2 Instance       │          │         EKS Pod              │   │
│  │                         │          │                              │   │
│  │  ┌─────┐  ┌─────┐      │          │  ┌─────────────────────┐    │   │
│  │  │Pod A│  │Pod B│      │          │  │   Service Account    │    │   │
│  │  └──┬──┘  └──┬──┘      │          │  │   (annotated with    │    │   │
│  │     │        │         │          │  │    IAM role ARN)     │    │   │
│  │     └────┬───┘         │          │  └──────────┬──────────┘    │   │
│  │          │             │          │             │               │   │
│  │          ▼             │          │             ▼               │   │
│  │    ┌──────────┐        │          │    ┌──────────────────┐    │   │
│  │    │ Instance │        │          │    │  OIDC Provider   │    │   │
│  │    │   Role   │        │          │    │  (Trust Policy)  │    │   │
│  │    │          │        │          │    └────────┬─────────┘    │   │
│  │    │ (Shared  │        │          │             │               │   │
│  │    │  by ALL  │        │          │             ▼               │   │
│  │    │  pods!)  │        │          │    ┌──────────────────┐    │   │
│  │    └──────────┘        │          │    │    IAM Role      │    │   │
│  └─────────────────────────┘          │    │  (Pod-specific)  │    │   │
│                                       │    └──────────────────┘    │   │
│  Problem: All pods get same           └─────────────────────────────┘   │
│  permissions = over-privileged                                          │
│                                       Benefit: Each pod gets only       │
│                                       the permissions it needs          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Security Layers

| Layer | Implementation | Purpose |
|-------|----------------|---------|
| Network | VPC, Security Groups | Isolate resources |
| Identity | IRSA, OIDC | Fine-grained pod permissions |
| Secrets | AWS Secrets Manager | Secure credential storage |
| Encryption | EBS encryption, RDS encryption | Data at rest |
| Node Security | IMDSv2, private subnets | Instance protection |

## Application Architecture

### TODO API Design

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           TODO API Architecture                          │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                         Kubernetes Resources                        │ │
│  │                                                                      │ │
│  │  ┌─────────────────┐    ┌─────────────────┐    ┌────────────────┐  │ │
│  │  │    Deployment   │    │     Service     │    │      HPA       │  │ │
│  │  │                 │    │                 │    │                │  │ │
│  │  │ replicas: 2-10  │◀───│  type: LB       │    │ min: 2         │  │ │
│  │  │                 │    │  port: 80       │    │ max: 10        │  │ │
│  │  │ ┌─────────────┐ │    │                 │    │ cpu: 70%       │  │ │
│  │  │ │   Pod       │ │    └─────────────────┘    │ memory: 80%    │  │ │
│  │  │ │             │ │                           └────────────────┘  │ │
│  │  │ │ ┌─────────┐ │ │                                               │ │
│  │  │ │ │Flask App│ │ │                                               │ │
│  │  │ │ │         │ │ │                                               │ │
│  │  │ │ │ :8080   │ │ │                                               │ │
│  │  │ │ └─────────┘ │ │                                               │ │
│  │  │ └─────────────┘ │                                               │ │
│  │  └─────────────────┘                                               │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                     │                                    │
│                                     │ PostgreSQL (5432)                  │
│                                     ▼                                    │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                              RDS                                    │ │
│  │  ┌─────────────────────────────────────────────────────────────┐  │ │
│  │  │                        PostgreSQL                            │  │ │
│  │  │                                                               │  │ │
│  │  │  Database: tododb                                             │  │ │
│  │  │  Table: todos (id, title, completed, created_at, updated_at) │  │ │
│  │  │                                                               │  │ │
│  │  └─────────────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check for K8s probes |
| GET | `/api/todos` | List all todos |
| POST | `/api/todos` | Create a todo |
| GET | `/api/todos/:id` | Get a specific todo |
| PUT | `/api/todos/:id` | Update a todo |
| DELETE | `/api/todos/:id` | Delete a todo |

## GitOps Workflow

### Deployment Flow (Planned)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           GitOps Workflow                                │
│                                                                          │
│   Developer          GitHub              ArgoCD            Kubernetes    │
│      │                  │                   │                   │        │
│      │  1. Push code    │                   │                   │        │
│      │─────────────────▶│                   │                   │        │
│      │                  │                   │                   │        │
│      │                  │  2. Webhook       │                   │        │
│      │                  │──────────────────▶│                   │        │
│      │                  │                   │                   │        │
│      │                  │  3. Pull changes  │                   │        │
│      │                  │◀──────────────────│                   │        │
│      │                  │                   │                   │        │
│      │                  │                   │  4. Apply manifests        │
│      │                  │                   │──────────────────▶│        │
│      │                  │                   │                   │        │
│      │                  │                   │  5. Report status │        │
│      │                  │                   │◀──────────────────│        │
│      │                  │                   │                   │        │
│      │  6. View status  │                   │                   │        │
│      │◀─────────────────────────────────────│                   │        │
│      │                  │                   │                   │        │
└─────────────────────────────────────────────────────────────────────────┘
```

## Design Decisions

### Why EKS over self-managed Kubernetes?

| Factor | EKS | Self-Managed |
|--------|-----|--------------|
| Control Plane | AWS manages | You manage |
| Upgrades | Automated | Manual |
| HA | Built-in | You configure |
| Cost | $73/month | EC2 instances |
| Integration | Native AWS | Manual setup |

**Decision**: EKS for reduced operational overhead and better AWS integration.

### Why Managed Node Groups over Fargate?

| Factor | Managed Nodes | Fargate |
|--------|---------------|---------|
| Control | Full (SSH, customization) | Limited |
| Cost | Predictable | Per-pod billing |
| Startup | Fast (pre-provisioned) | Slower (cold start) |
| DaemonSets | Supported | Not supported |
| Storage | EBS volumes | Limited |

**Decision**: Managed Node Groups for flexibility and DaemonSet support.

### Why PostgreSQL on RDS over in-cluster?

| Factor | RDS | In-Cluster |
|--------|-----|------------|
| Management | AWS handles backups, patches | You manage everything |
| HA | Multi-AZ built-in | Complex to configure |
| Performance | Optimized | Shared with other workloads |
| Cost | Higher | Lower (shared nodes) |

**Decision**: RDS for reliability and reduced operational burden.

### Why Secrets Manager over Kubernetes Secrets?

| Factor | Secrets Manager | K8s Secrets |
|--------|-----------------|-------------|
| Encryption | AWS KMS | Base64 only (by default) |
| Rotation | Automatic | Manual |
| Audit | CloudTrail | Limited |
| Access | IAM policies | RBAC |
| Integration | External Secrets Operator | Native |

**Decision**: Secrets Manager for better security and audit capabilities.

## Cost Considerations

### Dev Environment (~$170/month optimized)

| Service | Configuration | Monthly Cost |
|---------|--------------|--------------|
| EKS Control Plane | 1 cluster | $73 |
| EC2 (Nodes) | 2x t3.medium | $60 |
| NAT Gateway | 1 (single mode) | $30 |
| RDS | db.t4g.micro | $12 |
| **Total** | | **~$175** |

### Production Environment (~$500/month)

| Service | Configuration | Monthly Cost |
|---------|--------------|--------------|
| EKS Control Plane | 1 cluster | $73 |
| EC2 (Nodes) | 3x t3.large | $180 |
| NAT Gateway | 3 (HA mode) | $90 |
| RDS | db.t4g.medium, Multi-AZ | $100 |
| ALB | 1 load balancer | $25 |
| **Total** | | **~$468** |

### Cost Optimization Tips

1. **Use SPOT instances** for non-critical workloads (60-90% savings)
2. **Single NAT Gateway** for dev environments
3. **Right-size instances** based on actual usage
4. **Reserved Instances** for predictable workloads (30-60% savings)
5. **Cleanup unused resources** (stale EBS snapshots, old ECR images)
