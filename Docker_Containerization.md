# Docker Containerization Documentation

## Overview

This document explains the Docker containerization strategy implemented for the Finch application, including frontend (Vue.js) and backend (Django) components, along with supporting infrastructure services.

## Container Architecture

### Multi-Stage Build Strategy

Both frontend and backend applications utilize multi-stage Docker builds to optimize image size, security, and build efficiency.

#### Benefits of Multi-Stage Builds:
- **Smaller Production Images**: Build dependencies are excluded from final images
- **Enhanced Security**: Reduced attack surface with minimal runtime dependencies
- **Better Caching**: Optimized layer caching for faster builds
- **Separation of Concerns**: Clear distinction between build and runtime environments

## Frontend Container (Vue.js)

### Dockerfile Structure

```dockerfile
# Stage 1: Build Stage
FROM node:18-alpine AS build
# - Uses Alpine Linux for smaller base image
# - Installs dependencies with npm ci for reproducible builds
# - Builds production-optimized Vue.js application

# Stage 2: Production Stage  
FROM nginx:1.25-alpine AS production
# - Serves static files with nginx
# - Includes security headers and gzip compression
# - Implements health checks and proper signal handling
```

### Key Features:

#### Security Enhancements:
- **Non-root User**: Runs as nginx user (UID 101)
- **Security Headers**: CSP, X-Frame-Options, X-Content-Type-Options
- **Minimal Attack Surface**: Only production dependencies included

#### Performance Optimizations:
- **Gzip Compression**: Enabled for all text-based assets
- **Static Asset Caching**: 1-year cache for immutable assets
- **HTTP/2 Support**: Through nginx configuration

#### Runtime Configuration:
- **Environment Variables**: API_URL configurable at runtime
- **SPA Routing**: Proper handling of client-side routing
- **Health Checks**: `/health` endpoint for monitoring

### Build Commands:

```bash
# Build frontend image
docker build -t finch-frontend:latest ./finch-frontend

# Run frontend container
docker run -d -p 3000:80 \
  -e API_URL=http://localhost:8000/api \
  finch-frontend:latest
```

## Backend Container (Django)

### Dockerfile Structure

```dockerfile
# Stage 1: Builder Stage
FROM python:3.11-slim AS builder
# - Installs build dependencies (gcc, libpq-dev, etc.)
# - Creates virtual environment with all Python packages
# - Optimizes pip installations with caching

# Stage 2: Production Stage
FROM python:3.11-slim AS production
# - Minimal runtime dependencies only
# - Copies virtual environment from builder
# - Implements security best practices
```

### Key Features:

#### Security Enhancements:
- **Non-root User**: Custom appuser (UID 1000)
- **Virtual Environment**: Isolated Python dependencies
- **Minimal Dependencies**: Only runtime libraries included
- **Health Checks**: Application health monitoring

#### Production Readiness:
- **Gunicorn WSGI Server**: Production-grade application server
- **Static File Handling**: Proper collection and serving
- **Database Migrations**: Automated migration execution
- **Signal Handling**: Graceful shutdown with dumb-init

#### Configuration Management:
- **Environment Variables**: 12-factor app compliance
- **Secrets Management**: Secure handling of sensitive data
- **Logging**: Structured logging to stdout

### Build Commands:

```bash
# Build backend image
docker build -t finch-backend:latest ./finch-backend

# Run backend container
docker run -d -p 8000:8000 \
  -e POSTGRES_HOST=postgres \
  -e POSTGRES_DB=fleetdb \
  -e POSTGRES_USER=roy77 \
  -e POSTGRES_PASSWORD=asdf1234@77 \
  finch-backend:latest
```

## Image Optimization Techniques

### Size Optimization:

#### 1. Multi-Stage Builds
- Build dependencies excluded from final images
- Frontend: 15MB (nginx + static files) vs 200MB+ (with Node.js)
- Backend: 150MB vs 300MB+ (with build tools)

#### 2. Alpine Linux Base Images
- Minimal attack surface
- Package manager optimizations
- Smaller download sizes

#### 3. Layer Caching Strategy
```dockerfile
# Dependencies installed first (cached layer)
COPY package*.json ./
RUN npm ci

# Source code copied last (frequently changing)
COPY . .
```

### Security Optimizations:

#### 1. Non-Root Users
- Frontend: nginx user (101)
- Backend: appuser (1000)
- Prevents privilege escalation attacks

#### 2. Minimal Dependencies
- Only runtime libraries in production images
- Regular security updates through base image updates
- Vulnerability scanning in CI/CD pipeline

#### 3. Health Checks
```dockerfile
HEALTHCHECK --interval=30s --timeout=10s \
  CMD curl -f http://localhost:8000/health/
```

## .dockerignore Files

### Frontend (.dockerignore):
```ignore
node_modules/
.git/
README.md
.env*
dist/
coverage/
```

### Backend (.dockerignore):
```ignore
__pycache__/
.git/
venv/
*.sqlite3
media/
staticfiles/
```

## Docker Compose for Local Development

### Services Included:
- **PostgreSQL**: Database with persistent storage
- **Redis**: Caching and message broker
- **Backend**: Django application with auto-reload
- **Frontend**: Vue.js application with hot reload
- **Celery Worker**: Background task processing
- **Celery Beat**: Scheduled task execution
- **Nginx**: Reverse proxy and static file serving
- **Prometheus**: Metrics collection
- **Grafana**: Monitoring dashboards

### Usage Commands:

```bash
# Start all services
docker-compose up -d

# View logs
docker-compose logs -f backend

# Stop all services
docker-compose down

# Rebuild and start
docker-compose up --build -d

# Scale services
docker-compose up -d --scale celery-worker=3
```

### Development Workflow:

1. **Initial Setup**:
   ```bash
   git clone <repository>
   cd finch-application
   docker-compose up -d
   ```

2. **Database Setup**:
   ```bash
   docker-compose exec backend python manage.py migrate
   docker-compose exec backend python manage.py createsuperuser
   ```

3. **Development**:
   - Backend: http://localhost:8000
   - Frontend: http://localhost:3000
   - Admin: http://localhost:8000/admin
   - Grafana: http://localhost:3001

## Production Deployment

### Registry Strategy:
- **Docker Hub**: Public images for open source
- **Private Registry**: Sensitive applications
- **Multi-architecture**: AMD64 and ARM64 support

### Tagging Strategy:
```bash
# Semantic versioning
docker tag finch-backend:latest finch-backend:v1.2.3

# Environment-specific tags
docker tag finch-backend:latest finch-backend:staging
docker tag finch-backend:latest finch-backend:production

# Git-based tags
docker tag finch-backend:latest finch-backend:commit-abc123
```

### Security Scanning:
```bash
# Trivy vulnerability scanning
trivy image finch-backend:latest

# Docker security scanning
docker scan finch-backend:latest
```

## Monitoring and Logging

### Container Metrics:
- CPU and memory usage
- Network I/O statistics
- Container restart counts
- Health check status

### Application Logs:
```bash
# View logs
docker-compose logs -f backend

# Export logs
docker-compose logs --no-color backend > backend.log
```

### Health Monitoring:
- HTTP health check endpoints
- Database connectivity checks
- External service dependency validation

## Troubleshooting

### Common Issues:

#### 1. Permission Denied
```bash
# Fix file permissions
chmod +x entrypoint.sh
docker-compose build --no-cache
```

#### 2. Database Connection
```bash
# Check database service
docker-compose ps postgres
docker-compose logs postgres

# Test connection
docker-compose exec backend python manage.py dbshell
```

#### 3. Build Failures
```bash
# Clean build
docker system prune -a
docker-compose build --no-cache

# Check build context
docker build -t test . --progress=plain --no-cache
```

#### 4. Memory Issues
```bash
# Increase Docker memory limit
# Docker Desktop > Settings > Resources > Advanced

# Monitor resource usage
docker stats
```

### Performance Tuning:

#### 1. Build Performance
- Use multi-stage builds
- Optimize layer caching
- Parallel builds with BuildKit

#### 2. Runtime Performance
- Configure resource limits
- Use appropriate restart policies
- Implement proper health checks

#### 3. Storage Performance
- Use named volumes for databases
- Implement log rotation
- Regular cleanup of unused images

## Best Practices Summary

### Security:
✅ Non-root users in all containers
✅ Minimal base images
✅ Regular security updates
✅ Secrets management via environment variables
✅ Network isolation with custom networks

### Performance:
✅ Multi-stage builds
✅ Layer caching optimization
✅ Health checks for all services
✅ Resource limits and monitoring
✅ Log aggregation and rotation

### Maintainability:
✅ Consistent naming conventions
✅ Comprehensive documentation
✅ Environment-specific configurations
✅ Automated testing in CI/CD
✅ Version pinning for dependencies

### Compliance:
✅ 12-factor app methodology
✅ Immutable infrastructure
✅ Configuration via environment
✅ Stateless application design
✅ Proper signal handling
