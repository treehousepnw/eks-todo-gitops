#!/bin/bash
set -e

echo "🛠️  EKS Tools Setup Script"
echo "========================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "⚠️  This script is designed for macOS. Adjust for your OS."
    exit 1
fi

echo "📦 Checking prerequisites..."
echo ""

# Check Homebrew
if ! command -v brew &> /dev/null; then
    echo "❌ Homebrew not found. Install from https://brew.sh"
    exit 1
fi
echo -e "${GREEN}✅ Homebrew installed${NC}"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    brew install awscli
fi
echo -e "${GREEN}✅ AWS CLI installed${NC}"
aws --version

# Check Terraform
if ! command -v terraform &> /dev/null; then
    echo "Installing Terraform..."
    brew install terraform
fi
echo -e "${GREEN}✅ Terraform installed${NC}"
terraform version

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo "Installing kubectl..."
    brew install kubectl
fi
echo -e "${GREEN}✅ kubectl installed${NC}"
kubectl version --client

# Check Helm
if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    brew install helm
fi
echo -e "${GREEN}✅ Helm installed${NC}"
helm version

# Check ArgoCD CLI
if ! command -v argocd &> /dev/null; then
    echo "Installing ArgoCD CLI..."
    brew install argocd
fi
echo -e "${GREEN}✅ ArgoCD CLI installed${NC}"
argocd version --client

# Optional: k9s (terminal UI for Kubernetes)
if ! command -v k9s &> /dev/null; then
    echo "Installing k9s (optional but awesome)..."
    brew install k9s
fi
echo -e "${GREEN}✅ k9s installed${NC}"

# Optional: kubectx/kubens
if ! command -v kubectx &> /dev/null; then
    echo "Installing kubectx/kubens..."
    brew install kubectx
fi
echo -e "${GREEN}✅ kubectx/kubens installed${NC}"

echo ""
echo "🎉 All tools installed successfully!"
echo ""
echo "📋 Next steps:"
echo "   1. Verify AWS credentials: aws sts get-caller-identity"
echo "   2. Deploy EKS cluster: cd terraform && terraform init"
echo "   3. Review and apply: terraform apply -var-file=environments/dev.tfvars"
echo ""