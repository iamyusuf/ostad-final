# Secret Management Documentation

## Overview

This document outlines the comprehensive secret management strategy implemented for the Finch application Kubernetes deployment. The strategy emphasizes security, automation, and operational simplicity while maintaining compliance with industry best practices.

## Secret Management Strategy

### Chosen Approach: Kubernetes Native Secrets + External Secret Operator

We have implemented a hybrid approach that provides both immediate functionality and future scalability:

#### Phase 1: Kubernetes Native Secrets (Current Implementation)
- **Base64 encoded secrets** stored in Kubernetes etcd
- **Encryption at rest** enabled in the cluster
- **RBAC controls** for secret access
- **Namespace isolation** for environment separation

#### Phase 2: External Secret Operator (Future Enhancement)
- **External secret stores** integration (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault)
- **Automatic secret rotation** capabilities
- **Centralized secret management** across multiple clusters

## Secret Categories and Organization

### 1. Database Credentials (`database-credentials`)

**Purpose**: PostgreSQL database connection credentials

**Contents**:
- `database-name`: Database name (fleetdb, fleetdb_staging)
- `database-user`: Database username
- `database-password`: Database password
- `database-url`: Complete connection string

**Security Measures**:
- Separate credentials for production and staging
- Strong password generation (16+ characters)
- Regular rotation schedule (quarterly)

**Usage Example**:
```yaml
env:
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: database-credentials
      key: database-password
```

### 2. Redis Credentials (`redis-credentials`)

**Purpose**: Redis cache and message broker authentication

**Contents**:
- `redis-password`: Redis AUTH password
- `redis-url`: Complete Redis connection URL
- `redis-url-no-auth`: Fallback URL for testing

**Security Measures**:
- 24-character random passwords
- URL encoding for special characters
- Separate instances per environment

### 3. Application Secrets (`app-secrets`)

**Purpose**: Core application security keys and tokens

**Contents**:
- `django-secret-key`: Django cryptographic signing key
- `jwt-secret-key`: JWT token signing key
- `email-username`: SMTP authentication username
- `email-password`: SMTP authentication password
- `aws-access-key-id`: AWS/cloud storage access key
- `aws-secret-access-key`: AWS/cloud storage secret key
- `sentry-dsn`: Error tracking service DSN

**Security Measures**:
- Django secret keys generated using Django's built-in utility
- 50+ character complexity for signing keys
- Environment-specific values for proper isolation

### 4. Payment Secrets (`payment-secrets`)

**Purpose**: Payment gateway API credentials

**Contents**:
- `stripe-publishable-key`: Stripe public API key
- `stripe-secret-key`: Stripe private API key
- `stripe-webhook-secret`: Stripe webhook verification key
- `paypal-client-id`: PayPal REST API client ID
- `paypal-client-secret`: PayPal REST API client secret
- `paystack-public-key`: Paystack public key (for African payments)
- `paystack-secret-key`: Paystack secret key

**Security Measures**:
- Test keys for staging environment
- Live keys only in production
- Webhook secret validation for security
- Regular key rotation per provider recommendations

### 5. SSL/TLS Certificates (`ssl-certificates`)

**Purpose**: HTTPS encryption certificates

**Contents**:
- `tls.crt`: X.509 certificate
- `tls.key`: Private key

**Security Measures**:
- Let's Encrypt integration for automatic renewal
- Strong encryption algorithms (RSA 2048+ or ECC P-256)
- Certificate transparency monitoring

### 6. Monitoring Secrets (`monitoring-secrets`)

**Purpose**: Observability and alerting system credentials

**Contents**:
- `grafana-admin-username`: Grafana admin username
- `grafana-admin-password`: Grafana admin password
- `prometheus-username`: Prometheus basic auth username
- `prometheus-password`: Prometheus basic auth password
- `slack-webhook-url`: Slack notification webhook
- `pagerduty-key`: PagerDuty integration key
- `smtp-username`: SMTP for alerting emails
- `smtp-password`: SMTP password

**Security Measures**:
- Strong administrative passwords
- Limited scope API keys
- Secure webhook URLs

## Secret Lifecycle Management

### 1. Secret Creation

#### Automated Generation:
```bash
# Use the provided script for interactive setup
./kubernetes/secrets/manage-secrets.sh setup production

# Or for staging
./kubernetes/secrets/manage-secrets.sh setup staging
```

#### Manual Generation:
```bash
# Generate Django secret key
python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"

# Generate random password
openssl rand -base64 32 | tr -d "=+/" | cut -c1-25

# Base64 encode for Kubernetes
echo -n "your-secret-value" | base64
```

### 2. Secret Application

#### Direct Application:
```bash
# Apply all secrets for production
kubectl apply -f kubernetes/secrets/ -n finch-production

# Apply specific secret
kubectl apply -f kubernetes/secrets/database-credentials.yaml
```

#### Using Management Script:
```bash
# Apply pre-generated secrets
./kubernetes/secrets/manage-secrets.sh apply production
```

### 3. Secret Rotation

#### Automated Rotation (Recommended):
```bash
# Rotate all secrets in production
./kubernetes/secrets/manage-secrets.sh rotate finch-production

# This will:
# 1. Backup existing secrets
# 2. Generate new values
# 3. Update secrets in Kubernetes
# 4. Require pod restart to pick up changes
```

#### Manual Rotation:
```bash
# Update specific secret key
kubectl patch secret database-credentials -n finch-production \
  --type='json' \
  -p='[{"op": "replace", "path": "/data/database-password", "value": "'$(echo -n "new-password" | base64)'"}]'

# Restart pods to pick up new secrets
kubectl rollout restart deployment/finch-backend -n finch-production
```

### 4. Secret Verification

#### Health Checks:
```bash
# Verify all secrets exist
./kubernetes/secrets/manage-secrets.sh verify finch-production

# Check specific secret
kubectl get secret database-credentials -n finch-production -o yaml

# Decode secret value (for debugging)
kubectl get secret database-credentials -n finch-production -o jsonpath='{.data.database-password}' | base64 -d
```

## Security Best Practices

### 1. Access Control (RBAC)

#### Service Accounts:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: finch-backend-sa
  namespace: finch-production
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: finch-production
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["database-credentials", "app-secrets", "payment-secrets"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: secret-reader-binding
  namespace: finch-production
subjects:
- kind: ServiceAccount
  name: finch-backend-sa
  namespace: finch-production
roleRef:
  kind: Role
  name: secret-reader
  apiGroup: rbac.authorization.k8s.io
```

### 2. Encryption

#### Encryption at Rest:
```yaml
# Example encryption configuration for etcd
apiVersion: apiserver.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: <base64-encoded-32-byte-key>
  - identity: {}
```

#### Encryption in Transit:
- All secret transmission over TLS
- kubectl communications encrypted
- etcd peer-to-peer encryption

### 3. Secret Scanning

#### Pre-commit Hooks:
```bash
# Install git-secrets
brew install git-secrets

# Configure for repository
git secrets --install
git secrets --register-aws

# Scan for secrets
git secrets --scan
```

#### CI/CD Integration:
```yaml
# GitHub Actions step for secret scanning
- name: Run secret scan
  uses: trufflesecurity/trufflehog@main
  with:
    path: ./
    base: main
    head: HEAD
```

### 4. Monitoring and Auditing

#### Secret Access Monitoring:
```yaml
# Example Prometheus alert for secret access
groups:
- name: secret-monitoring
  rules:
  - alert: UnauthorizedSecretAccess
    expr: increase(apiserver_audit_total{verb="get",objectRef_resource="secrets"}[5m]) > 10
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "High number of secret accesses detected"
```

#### Audit Logging:
```yaml
# Kubernetes audit policy for secrets
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: RequestResponse
  resources:
  - group: ""
    resources: ["secrets"]
```

## Backup and Recovery

### 1. Secret Backup Strategy

#### Automated Backups:
```bash
# Daily backup script
#!/bin/bash
BACKUP_DIR="/backup/secrets/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# Backup all secrets
kubectl get secrets --all-namespaces -o yaml > "$BACKUP_DIR/all-secrets.yaml"

# Encrypt backup
gpg --symmetric --cipher-algo AES256 "$BACKUP_DIR/all-secrets.yaml"
rm "$BACKUP_DIR/all-secrets.yaml"
```

#### Manual Backup:
```bash
# Use management script
./kubernetes/secrets/manage-secrets.sh backup finch-production

# Or manual kubectl
kubectl get secrets -n finch-production -o yaml > secrets-backup-$(date +%Y%m%d).yaml
```

### 2. Disaster Recovery

#### Recovery Procedure:
1. **Restore from backup**:
   ```bash
   # Decrypt and restore
   gpg --decrypt secrets-backup-20241206.yaml.gpg | kubectl apply -f -
   ```

2. **Verify restoration**:
   ```bash
   ./kubernetes/secrets/manage-secrets.sh verify finch-production
   ```

3. **Restart affected services**:
   ```bash
   kubectl rollout restart deployment/finch-backend -n finch-production
   kubectl rollout restart deployment/finch-frontend -n finch-production
   ```

## Integration with External Secret Stores

### Future Implementation: HashiCorp Vault

#### Installation:
```bash
# Install Vault using Helm
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault --set='server.dev.enabled=true'
```

#### External Secrets Operator:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: finch-production
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "finch-role"
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: database-credentials-external
  namespace: finch-production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: database-credentials
    creationPolicy: Owner
  data:
  - secretKey: database-password
    remoteRef:
      key: finch/database
      property: password
```

### Integration with Cloud Providers

#### AWS Secrets Manager:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: finch-production
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-west-2
      auth:
        secretRef:
          accessKeyIDSecretRef:
            name: aws-credentials
            key: access-key-id
          secretAccessKeySecretRef:
            name: aws-credentials
            key: secret-access-key
```

#### Azure Key Vault:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: azure-keyvault
  namespace: finch-production
spec:
  provider:
    azurekv:
      vaultUrl: "https://finch-keyvault.vault.azure.net/"
      authType: WorkloadIdentity
      serviceAccountRef:
        name: finch-backend-sa
```

## Troubleshooting

### Common Issues

#### 1. Secret Not Found Error:
```bash
# Check if secret exists
kubectl get secrets -n finch-production

# Check secret content
kubectl describe secret database-credentials -n finch-production

# Verify RBAC permissions
kubectl auth can-i get secrets --as=system:serviceaccount:finch-production:finch-backend-sa
```

#### 2. Base64 Decoding Issues:
```bash
# Proper decoding
kubectl get secret database-credentials -n finch-production -o jsonpath='{.data.database-password}' | base64 -d

# Check for trailing newlines
kubectl get secret database-credentials -n finch-production -o jsonpath='{.data.database-password}' | base64 -d | wc -c
```

#### 3. Secret Mount Failures:
```bash
# Check pod events
kubectl describe pod <pod-name> -n finch-production

# Verify volume mounts
kubectl get pod <pod-name> -n finch-production -o yaml | grep -A 10 volumeMounts
```

#### 4. Permission Denied:
```bash
# Check service account
kubectl get serviceaccount finch-backend-sa -n finch-production

# Verify role bindings
kubectl get rolebinding -n finch-production
```

## Compliance and Governance

### Security Standards:
- **SOC 2 Type II**: Secret access logging and monitoring
- **PCI DSS**: Payment credential protection
- **GDPR**: Personal data encryption requirements
- **HIPAA**: Healthcare data protection (if applicable)

### Audit Requirements:
- Secret access logging
- Regular access reviews
- Secret rotation tracking
- Compliance reporting

### Documentation Requirements:
- Secret inventory maintenance
- Access control documentation
- Incident response procedures
- Recovery testing records

## Operational Procedures

### Daily Operations:
- Monitor secret access patterns
- Review failed authentication attempts
- Check backup completion status
- Validate certificate expiration dates

### Weekly Operations:
- Review secret access logs
- Update secret inventory
- Test backup restoration procedures
- Security scan results review

### Monthly Operations:
- Rotate development/staging secrets
- Access control review
- Compliance audit preparation
- Disaster recovery testing

### Quarterly Operations:
- Production secret rotation
- Full security assessment
- Business continuity testing
- Policy and procedure updates

This comprehensive secret management strategy ensures the security, availability, and compliance of the Finch application while providing operational flexibility and automation capabilities.
