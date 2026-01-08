#!/bin/bash
set -e

# EKS Cluster Deployment Script
ENV=${1:-dev}
AWS_REGION="us-west-2"

echo "🚀 Deploying EKS Cluster"
echo "========================"
echo "Environment: $ENV"
echo "Region: $AWS_REGION"
echo ""

# Check prerequisites
command -v terraform >/dev/null 2>&1 || { echo "❌ terraform required but not installed"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "❌ aws CLI required but not installed"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl required but not installed"; exit 1; }

# Verify AWS credentials
echo "🔐 Verifying AWS credentials..."
aws sts get-caller-identity || { echo "❌ AWS credentials not configured"; exit 1; }
echo "✅ AWS credentials verified"
echo ""

# Get AWS Account ID for backend
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="eks-todo-gitops-terraform-state-${AWS_ACCOUNT_ID}"

echo "📦 Backend S3 bucket: $BUCKET_NAME"
echo ""

# Check if bucket exists, create if not
if ! aws s3 ls "s3://${BUCKET_NAME}" 2>&1 >/dev/null; then
    echo "Creating S3 bucket for Terraform state..."
    aws s3api create-bucket \
        --bucket "${BUCKET_NAME}" \
        --region "${AWS_REGION}" \
        --create-bucket-configuration LocationConstraint="${AWS_REGION}"
    
    aws s3api put-bucket-versioning \
        --bucket "${BUCKET_NAME}" \
        --versioning-configuration Status=Enabled
    
    aws s3api put-bucket-encryption \
        --bucket "${BUCKET_NAME}" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'
    
    echo "✅ S3 bucket created"
fi

# Check if DynamoDB table exists
if ! aws dynamodb describe-table --table-name terraform-state-lock --region "${AWS_REGION}" &>/dev/null; then
    echo "Creating DynamoDB table for state locking..."
    aws dynamodb create-table \
        --table-name terraform-state-lock \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "${AWS_REGION}"
    
    echo "✅ DynamoDB table created"
fi

echo ""
echo "🏗️  Initializing Terraform..."
cd terraform

terraform init \
    -backend-config="bucket=${BUCKET_NAME}" \
    -backend-config="key=eks-todo-gitops/${ENV}/terraform.tfstate"

echo ""
echo "📋 Planning infrastructure..."
terraform plan -var-file="environments/${ENV}.tfvars" -out=tfplan

echo ""
read -p "🤔 Apply this plan? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "❌ Deployment cancelled"
    rm -f tfplan
    exit 1
fi

echo ""
echo "🚀 Applying infrastructure..."
echo "⏱️  This will take 10-15 minutes..."
terraform apply tfplan

rm -f tfplan

echo ""
echo "✅ EKS Cluster deployed successfully!"
echo ""

# Configure kubectl
CLUSTER_NAME=$(terraform output -raw cluster_name)
echo "⚙️  Configuring kubectl..."
aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

echo ""
echo "🎉 Deployment complete!"
echo ""
echo "📊 Cluster info:"
kubectl cluster-info

echo ""
echo "🔍 Nodes:"
kubectl get nodes

echo ""
echo "📋 Next steps:"
echo "   1. Verify nodes are ready: kubectl get nodes"
echo "   2. Deploy platform services: ./scripts/deploy-platform.sh"
echo "   3. Check costs in AWS Console"
echo ""
echo "💰 Estimated monthly cost: ~\$170 for dev environment"
echo ""