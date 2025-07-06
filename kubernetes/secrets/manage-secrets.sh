#!/bin/bash

# Secret Management Script for Finch Application
# This script helps generate, encode, and apply Kubernetes secrets securely

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to encode string to base64
encode_base64() {
    echo -n "$1" | base64 | tr -d '\n'
}

# Function to generate random password
generate_password() {
    local length=${1:-32}
    openssl rand -base64 $length | tr -d "=+/" | cut -c1-$length
}

# Function to generate Django secret key
generate_django_secret() {
    python3 -c "
from django.core.management.utils import get_random_secret_key
print(get_random_secret_key())
" 2>/dev/null || openssl rand -base64 64 | tr -d "=+/" | cut -c1-50
}

# Function to create namespace if it doesn't exist
create_namespace() {
    local namespace=$1
    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        log_info "Creating namespace: $namespace"
        kubectl create namespace "$namespace"
        log_success "Namespace $namespace created"
    else
        log_info "Namespace $namespace already exists"
    fi
}

# Function to backup existing secrets
backup_secrets() {
    local namespace=$1
    local backup_dir="./secret-backups/$(date +%Y%m%d-%H%M%S)"
    
    log_info "Backing up existing secrets for namespace: $namespace"
    mkdir -p "$backup_dir"
    
    kubectl get secrets -n "$namespace" -o yaml > "$backup_dir/secrets-$namespace.yaml" 2>/dev/null || true
    log_success "Secrets backed up to: $backup_dir"
}

# Function to validate secret values
validate_secrets() {
    log_info "Validating secret configurations..."
    
    # Check if required tools are available
    command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed"; exit 1; }
    command -v openssl >/dev/null 2>&1 || { log_error "openssl is required but not installed"; exit 1; }
    
    # Check cluster connectivity
    kubectl cluster-info >/dev/null 2>&1 || { log_error "Cannot connect to Kubernetes cluster"; exit 1; }
    
    log_success "Secret validation passed"
}

# Function to prompt for secret values
prompt_for_secrets() {
    local env=$1
    
    log_info "Setting up secrets for environment: $env"
    
    # Database credentials
    read -p "Database name [fleetdb]: " DB_NAME
    DB_NAME=${DB_NAME:-fleetdb}
    if [ "$env" = "staging" ]; then
        DB_NAME="${DB_NAME}_staging"
    fi
    
    read -p "Database user [roy77]: " DB_USER
    DB_USER=${DB_USER:-roy77}
    
    read -s -p "Database password: " DB_PASSWORD
    echo
    if [ -z "$DB_PASSWORD" ]; then
        DB_PASSWORD=$(generate_password 16)
        log_warning "Generated random database password: $DB_PASSWORD"
    fi
    
    # Redis credentials
    REDIS_PASSWORD=$(generate_password 24)
    log_info "Generated Redis password: $REDIS_PASSWORD"
    
    # Django secret key
    DJANGO_SECRET=$(generate_django_secret)
    log_info "Generated Django secret key"
    
    # JWT secret
    JWT_SECRET=$(generate_password 32)
    log_info "Generated JWT secret key"
    
    # Stripe keys (if provided)
    read -p "Stripe publishable key (optional): " STRIPE_PUB_KEY
    read -s -p "Stripe secret key (optional): " STRIPE_SECRET_KEY
    echo
    
    # Export variables for use in templates
    export DB_NAME DB_USER DB_PASSWORD REDIS_PASSWORD DJANGO_SECRET JWT_SECRET STRIPE_PUB_KEY STRIPE_SECRET_KEY
}

# Function to generate secret manifests from templates
generate_secret_manifests() {
    local env=$1
    local namespace="finch-$env"
    local output_dir="./generated-secrets/$env"
    
    log_info "Generating secret manifests for $env environment"
    mkdir -p "$output_dir"
    
    # Database credentials
    cat > "$output_dir/database-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: database-credentials
  namespace: $namespace
  labels:
    app: finch
    component: database
    environment: $env
type: Opaque
data:
  database-name: $(encode_base64 "$DB_NAME")
  database-user: $(encode_base64 "$DB_USER")
  database-password: $(encode_base64 "$DB_PASSWORD")
  database-url: $(encode_base64 "postgresql://$DB_USER:$DB_PASSWORD@postgresql:5432/$DB_NAME")
EOF

    # Redis credentials
    cat > "$output_dir/redis-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: redis-credentials
  namespace: $namespace
  labels:
    app: finch
    component: cache
    environment: $env
type: Opaque
data:
  redis-password: $(encode_base64 "$REDIS_PASSWORD")
  redis-url: $(encode_base64 "redis://:$REDIS_PASSWORD@redis:6379/0")
EOF

    # Application secrets
    cat > "$output_dir/app-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: $namespace
  labels:
    app: finch
    component: backend
    environment: $env
type: Opaque
data:
  django-secret-key: $(encode_base64 "$DJANGO_SECRET")
  jwt-secret-key: $(encode_base64 "$JWT_SECRET")
EOF

    # Payment secrets (if provided)
    if [ -n "$STRIPE_PUB_KEY" ] && [ -n "$STRIPE_SECRET_KEY" ]; then
        cat > "$output_dir/payment-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: payment-secrets
  namespace: $namespace
  labels:
    app: finch
    component: payment
    environment: $env
type: Opaque
data:
  stripe-publishable-key: $(encode_base64 "$STRIPE_PUB_KEY")
  stripe-secret-key: $(encode_base64 "$STRIPE_SECRET_KEY")
EOF
    fi
    
    log_success "Secret manifests generated in: $output_dir"
}

# Function to apply secrets to cluster
apply_secrets() {
    local env=$1
    local namespace="finch-$env"
    local manifest_dir="./generated-secrets/$env"
    
    log_info "Applying secrets to namespace: $namespace"
    
    # Create namespace
    create_namespace "$namespace"
    
    # Apply all secret manifests
    if [ -d "$manifest_dir" ]; then
        kubectl apply -f "$manifest_dir/" -n "$namespace"
        log_success "Secrets applied to $namespace"
    else
        log_error "Secret manifests not found in: $manifest_dir"
        return 1
    fi
}

# Function to verify secrets
verify_secrets() {
    local namespace=$1
    
    log_info "Verifying secrets in namespace: $namespace"
    
    local secrets=(
        "database-credentials"
        "redis-credentials"
        "app-secrets"
    )
    
    for secret in "${secrets[@]}"; do
        if kubectl get secret "$secret" -n "$namespace" >/dev/null 2>&1; then
            log_success "✓ Secret '$secret' exists"
        else
            log_error "✗ Secret '$secret' missing"
        fi
    done
}

# Function to rotate secrets
rotate_secrets() {
    local namespace=$1
    
    log_warning "This will rotate all secrets in namespace: $namespace"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Secret rotation cancelled"
        return 0
    fi
    
    backup_secrets "$namespace"
    
    # Generate new secrets
    log_info "Generating new secret values..."
    
    # Rotate database password
    NEW_DB_PASSWORD=$(generate_password 16)
    kubectl patch secret database-credentials -n "$namespace" \
        --type='json' \
        -p='[{"op": "replace", "path": "/data/database-password", "value": "'$(encode_base64 "$NEW_DB_PASSWORD")'"}]'
    
    # Rotate Redis password
    NEW_REDIS_PASSWORD=$(generate_password 24)
    kubectl patch secret redis-credentials -n "$namespace" \
        --type='json' \
        -p='[{"op": "replace", "path": "/data/redis-password", "value": "'$(encode_base64 "$NEW_REDIS_PASSWORD")'"}]'
    
    # Rotate Django secret key
    NEW_DJANGO_SECRET=$(generate_django_secret)
    kubectl patch secret app-secrets -n "$namespace" \
        --type='json' \
        -p='[{"op": "replace", "path": "/data/django-secret-key", "value": "'$(encode_base64 "$NEW_DJANGO_SECRET")'"}]'
    
    log_success "Secrets rotated successfully"
    log_warning "Remember to restart all pods to pick up new secrets"
}

# Function to clean up test secrets
cleanup_secrets() {
    local namespace=$1
    
    log_warning "This will delete all secrets in namespace: $namespace"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled"
        return 0
    fi
    
    backup_secrets "$namespace"
    kubectl delete secrets --all -n "$namespace"
    log_success "Secrets cleaned up from namespace: $namespace"
}

# Main script logic
main() {
    case "$1" in
        "setup")
            validate_secrets
            local env=${2:-production}
            prompt_for_secrets "$env"
            generate_secret_manifests "$env"
            apply_secrets "$env"
            verify_secrets "finch-$env"
            ;;
        "apply")
            local env=${2:-production}
            apply_secrets "$env"
            verify_secrets "finch-$env"
            ;;
        "verify")
            local namespace=${2:-finch-production}
            verify_secrets "$namespace"
            ;;
        "rotate")
            local namespace=${2:-finch-production}
            rotate_secrets "$namespace"
            ;;
        "backup")
            local namespace=${2:-finch-production}
            backup_secrets "$namespace"
            ;;
        "cleanup")
            local namespace=${2:-finch-staging}
            cleanup_secrets "$namespace"
            ;;
        *)
            echo "Usage: $0 {setup|apply|verify|rotate|backup|cleanup} [environment/namespace]"
            echo ""
            echo "Commands:"
            echo "  setup [env]     - Interactive setup of secrets (production|staging)"
            echo "  apply [env]     - Apply pre-generated secrets"
            echo "  verify [ns]     - Verify secrets exist in namespace"
            echo "  rotate [ns]     - Rotate secrets in namespace"
            echo "  backup [ns]     - Backup secrets from namespace"
            echo "  cleanup [ns]    - Delete all secrets in namespace"
            echo ""
            echo "Examples:"
            echo "  $0 setup production"
            echo "  $0 setup staging"
            echo "  $0 verify finch-production"
            echo "  $0 rotate finch-production"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
