# EKS TODO API with GitOps

Production-grade Kubernetes deployment on Amazon EKS with GitOps using ArgoCD, demonstrating modern cloud-native practices and DevOps methodologies.

## Project Overview

This project deploys a TODO REST API on Amazon EKS with:
- **GitOps** deployment model using ArgoCD
- **Infrastructure as Code** with Terraform
- **Observability** stack with Prometheus and Grafana
- **Auto-scaling** with Horizontal Pod Autoscaler and Cluster Autoscaler
- **AWS Integration** using IRSA (IAM Roles for Service Accounts)

## Architecture

```
┌─────────────────────────────────────────────────┐
│              GitHub Repositories                 │
│  ┌──────────────┐     ┌──────────────┐         │
│  │Infrastructure│     │ Applications │         │
│  └──────┬───────┘     └──────┬───────┘         │
└─────────┼──────────────────────┼─────────────────┘
          │                      │
          ▼                      ▼
┌────────────────EKS Cluster──────────────────────┐
│                                                  │
│  Control Plane (Managed by AWS)                 │
│  ┌────────────────────────────────┐            │
│  │ • K8s API Server                │            │
│  │ • etcd                          │            │
│  │ • Scheduler                     │            │
│  └────────────────────────────────┘            │
│                                                  │
│  Worker Nodes (EC2 in Private Subnets)         │
│  ┌────────────────────────────────┐            │
│  │ Platform Services:              │            │
│  │ • ArgoCD (GitOps)              │            │
│  │ • AWS Load Balancer Controller │            │
│  │ • External Secrets Operator    │            │
│  │ • Metrics Server               │            │
│  │ • Cluster Autoscaler           │            │
│  │                                 │            │
│  │ Application Workloads:          │            │
│  │ • TODO API (2-10 pods)         │            │
│  │ • HPA (auto-scaling)           │            │
│  │                                 │            │
│  │ Monitoring:                     │            │
│  │ • Prometheus                    │            │
│  │ • Grafana                       │            │
│  └────────────────────────────────┘            │
└──────────────────────────────────────────────────┘
          │
          ▼
    AWS Services
    • RDS PostgreSQL
    • Secrets Manager
    • ALB (Ingress)
    • ECR
```

## Prerequisites

### Tools Required
- AWS CLI (configured with credentials)
- Terraform >= 1.5.0
- kubectl >= 1.28
- Helm >= 3.12
- ArgoCD CLI (optional but recommended)

### Quick Setup
```bash
# Run the setup script (macOS)
chmod +x scripts/setup-tools.sh
./scripts/setup-tools.sh
```

## Quick Start

### 1. Clone and Setup

```bash
git clone https://github.com/your-username/eks-todo-gitops.git
cd eks-todo-gitops
```

### 2. Deploy EKS Cluster

```bash
# Deploy dev environment
chmod +x scripts/deploy-cluster.sh
./scripts/deploy-cluster.sh dev
```

This will:
- Create VPC with public/private subnets
- Deploy EKS control plane
- Launch managed node groups
- Configure kubectl access
- Create base namespaces

**Time:** ~15 minutes

### 3. Verify Cluster

```bash
# Check cluster
kubectl cluster-info

# Check nodes
kubectl get nodes

# Check namespaces
kubectl get namespaces
```

## Project Structure

```
eks-todo-gitops/
├── terraform/
│   ├── vpc/              # VPC module
│   ├── eks/              # EKS cluster module
│   ├── main.tf           # Root module
│   ├── variables.tf
│   ├── outputs.tf
│   └── environments/
│       └── dev.tfvars    # Dev configuration
├── kubernetes/
│   ├── platform/         # Platform services (Week 2)
│   ├── monitoring/       # Observability (Week 5)
│   └── apps/             # Applications (Week 3)
├── helm/
│   └── todo-api/         # Helm chart (Week 3)
├── scripts/
│   ├── setup-tools.sh
│   └── deploy-cluster.sh
└── README.md
```

## Learning Outcomes

### Week 1 (Current): EKS Foundation ✅
- [x] VPC design for EKS
- [x] EKS cluster deployment
- [x] Managed node groups
- [x] IAM Roles for Service Accounts (IRSA)
- [x] kubectl configuration

### Week 2: Platform Services
- [ ] AWS Load Balancer Controller
- [ ] External Secrets Operator
- [ ] Metrics Server
- [ ] Cluster Autoscaler

### Week 3: Application Deployment
- [ ] Helm chart development
- [ ] Kubernetes manifests
- [ ] ConfigMaps and Secrets
- [ ] Ingress configuration

### Week 4: GitOps with ArgoCD
- [ ] ArgoCD installation
- [ ] Application repository structure
- [ ] Automated deployments
- [ ] Multi-environment setup

### Week 5: Observability
- [ ] Prometheus Operator
- [ ] Grafana dashboards
- [ ] Application metrics
- [ ] Alerting rules

## Cost Breakdown

### Dev Environment (Monthly)
| Service | Configuration | Cost |
|---------|--------------|------|
| EKS Control Plane | Managed | $73 |
| EC2 Nodes | 2x t3.medium | $60 |
| NAT Gateway | 3 AZs | $105 |
| ALB | 1 load balancer | $20 |
| EBS Volumes | 40GB total | $4 |
| **Total** |  | **~$262/month** |

### Cost Optimization Tips
- Use **SPOT instances** for nodes (70% savings)
- Use **1 NAT Gateway** instead of 3 for dev (saves $70)
- **Scale down** nodes when not in use
- Use **t3.small** instead of t3.medium (saves $30)

**Optimized dev cost: ~$120/month**

## Common Commands

```bash
# Get cluster info
kubectl cluster-info

# List all pods
kubectl get pods --all-namespaces

# Check node status
kubectl get nodes -o wide

# View logs
kubectl logs -f <pod-name> -n <namespace>

# Exec into pod
kubectl exec -it <pod-name> -n <namespace> -- /bin/bash

# Port forward
kubectl port-forward svc/<service-name> 8080:80 -n <namespace>

# Apply manifests
kubectl apply -f <file.yaml>

# Delete resources
kubectl delete -f <file.yaml>
```

## Troubleshooting Guide

### Port Conflicts with kubectl port-forward

**Symptom**: `unable to listen on port` or `address already in use`

**Cause**: Another process (previous port-forward, local server) is using the port.

**Solution**:
```bash
# Find what's using the port
lsof -i :8080

# Kill the process
kill -9 <PID>

# Or use a different local port
kubectl port-forward svc/todo-api 9090:80 -n apps
```

### Docker Image Caching Issues

**Symptom**: Changes to application code don't appear after deployment.

**Cause**: Kubernetes pulls cached image because tag (`:latest`) hasn't changed.

**Solutions**:
```bash
# Option 1: Force image pull (temporary)
kubectl rollout restart deployment/todo-api -n apps

# Option 2: Use unique tags (recommended)
docker build -t todo-api:v1.0.1 .
# Update values.yaml with new tag

# Option 3: Set imagePullPolicy in deployment
# spec.containers[].imagePullPolicy: Always
```

### DNS Resolution Failures in Pods

**Symptom**: Pods can't resolve hostnames (RDS endpoint, external services).

**Cause**: CoreDNS not running or misconfigured.

**Diagnosis**:
```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Test DNS from a pod
kubectl run -it --rm debug --image=busybox -- nslookup kubernetes.default

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns
```

**Solutions**:
```bash
# Restart CoreDNS
kubectl rollout restart deployment/coredns -n kube-system

# If CoreDNS pods are pending, check node resources
kubectl describe nodes | grep -A 5 "Allocated resources"
```

### Database Connection Errors

**Symptom**: `could not connect to server` or `connection refused`

**Diagnosis**:
```bash
# Check if RDS is accessible from pod
kubectl run -it --rm debug --image=postgres:15 -n apps -- \
  psql -h <RDS_ENDPOINT> -U todoadmin -d tododb

# Check security group allows traffic
# RDS SG should allow ingress on 5432 from EKS node SG
```

**Common causes**:
1. Security group not allowing EKS → RDS traffic
2. RDS in different VPC or wrong subnets
3. Incorrect credentials (check Secrets Manager)

### Nodes Not Ready

**Symptom**: `kubectl get nodes` shows NotReady status

**Diagnosis**:
```bash
# Check node conditions
kubectl describe node <node-name>

# Check kubelet logs (on the node or via SSM)
kubectl logs -n kube-system -l k8s-app=aws-node

# Check for resource pressure
kubectl top nodes
```

**Common causes**:
1. Node out of disk space
2. Too many pods (IP exhaustion)
3. VPC CNI issues

### Pods Stuck in Pending/CrashLoopBackOff

**Diagnosis**:
```bash
# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Describe pod for scheduling issues
kubectl describe pod <pod-name> -n <namespace>

# Check logs for crash reasons
kubectl logs <pod-name> -n <namespace> --previous
```

**Common causes**:
- **Pending**: Insufficient resources, node selector mismatch, PVC not bound
- **CrashLoopBackOff**: Application error, missing env vars, bad config

### kubectl Connection Issues

```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-west-2 --name <cluster-name>

# Verify AWS credentials
aws sts get-caller-identity

# Check cluster endpoint is reachable
curl -k https://<cluster-endpoint>/healthz

# Verify connection
kubectl cluster-info
```

### Image Pull Errors (ImagePullBackOff)

**Symptom**: Pod stuck in `ImagePullBackOff` or `ErrImagePull`

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n <namespace> | grep -A 10 Events
```

**Common causes and solutions**:
```bash
# 1. ECR login expired - re-authenticate
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin <account>.dkr.ecr.us-west-2.amazonaws.com

# 2. Image doesn't exist - verify image
aws ecr describe-images --repository-name <repo-name>

# 3. Node can't reach ECR - check NAT Gateway and security groups
```

### HPA Not Scaling

**Symptom**: HPA shows `<unknown>` for metrics

**Cause**: Metrics server not installed or not collecting metrics.

**Solution**:
```bash
# Check metrics server
kubectl get deployment metrics-server -n kube-system

# Install if missing
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Verify metrics
kubectl top pods -n apps
```

## Cleanup

To destroy the cluster and avoid charges:

```bash
cd terraform
terraform destroy -var-file=environments/dev.tfvars
```

**Warning:** This will delete all resources including the cluster and data.

## Resources

- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Helm Documentation](https://helm.sh/docs/)

## Author

**Derek Ogletree**
- Portfolio: [TreehousePNW](https://github.com/treehousepnw/)
- LinkedIn: [linkedin.com/in/trenigma](https://linkedin.com/in/trenigma)
- Blog: [blog.trenigma.dev](https://blog.trenigma.dev)

## License

This project is for portfolio and educational purposes.

---

**Status:** Week 1 Complete ✅ | Next: Platform Services

*Built with ❤️ for learning Kubernetes and modern DevOps practices*