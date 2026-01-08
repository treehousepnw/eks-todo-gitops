# Contributing to EKS TODO GitOps

Thank you for your interest in contributing! This is a portfolio/learning project, but contributions are welcome.

## Getting Started

1. **Fork the repository**
2. **Clone your fork**
   ```bash
   git clone https://github.com/treehousepnw/eks-todo-gitops.git
   cd eks-todo-gitops
   ```
3. **Create a branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Development Setup

### Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.5.0
- kubectl >= 1.28
- Helm >= 3.12
- Python 3.11+ (for the TODO API)
- Docker (for local testing)

### Local Development

```bash
# Install tools (macOS)
./scripts/setup-tools.sh

# Copy example configs
cp helm/todo-api/values.example.yaml helm/todo-api/values.yaml

# Run the API locally with Docker
cd app
docker build -t todo-api:local .
docker run -p 8080:8080 -e DB_HOST=host.docker.internal todo-api:local
```

## Code Standards

### Terraform

- Run `terraform fmt` before committing
- Run `terraform validate` to check syntax
- Use meaningful resource names with the `${var.project_name}-${var.environment}` prefix
- Add comments explaining non-obvious configurations
- Group related resources together

### Python

- Follow PEP 8 style guidelines
- Add docstrings to all functions
- Use type hints where appropriate
- Keep functions small and focused

### Helm Charts

- Use `.example.yaml` for templates with placeholder values
- Never commit actual credentials or endpoints
- Test charts with `helm lint` and `helm template`

### Commits

- Use clear, descriptive commit messages
- Reference issues where applicable
- Keep commits focused on a single change

Example:
```
feat(terraform): add RDS multi-AZ support

- Add multi_az variable to RDS module
- Update dev.tfvars with default setting
- Document in README

Closes #42
```

## Pull Request Process

1. **Update documentation** for any changed functionality
2. **Test your changes** locally or in a dev environment
3. **Run linters** (`terraform fmt`, `helm lint`)
4. **Write a clear PR description** explaining:
   - What the change does
   - Why it's needed
   - How to test it
5. **Request review** from maintainers

## Project Structure

```
eks-todo-gitops/
├── terraform/           # Infrastructure as Code
│   ├── vpc/            # VPC module
│   ├── eks/            # EKS cluster module
│   ├── rds/            # RDS PostgreSQL module
│   ├── ecr/            # Container registry module
│   └── environments/   # Environment-specific configs
├── helm/               # Helm charts
│   └── todo-api/       # TODO API chart
├── app/                # Application source code
├── scripts/            # Utility scripts
├── kubernetes/         # Raw K8s manifests (future)
└── docs/               # Documentation
```

## Reporting Issues

When reporting issues, please include:

- Description of the problem
- Steps to reproduce
- Expected vs actual behavior
- Environment details (OS, tool versions)
- Relevant logs or error messages

## Questions?

Feel free to open an issue for questions or discussions about the project.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
