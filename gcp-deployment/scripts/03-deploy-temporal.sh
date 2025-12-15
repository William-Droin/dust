#!/bin/bash
# =============================================================================
# Dust Temporal Deployment Script
# =============================================================================
# This script deploys self-hosted Temporal to GKE using Helm.
# Run this AFTER 02-deploy-infrastructure.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
PROJECT_ID="${PROJECT_ID:-dust-production}"
REGION="${REGION:-europe-west1}"
GKE_CLUSTER_NAME="dust-cluster"
NAMESPACE="temporal"

# Get Cloud SQL connection info from Secret Manager
TEMPORAL_DB_URI=$(gcloud secrets versions access latest --secret="dust-temporal-uri" 2>/dev/null || echo "")

# =============================================================================
# COLORS FOR OUTPUT
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
log_info "Starting Temporal deployment..."

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    log_error "Helm is not installed. Please install it first:"
    log_error "  brew install helm (macOS)"
    log_error "  or visit: https://helm.sh/docs/intro/install/"
    exit 1
fi

# Get GKE credentials
gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" --region="${REGION}"

# =============================================================================
# ADD TEMPORAL HELM REPO
# =============================================================================
log_info "Adding Temporal Helm repository..."
helm repo add temporal https://go.temporal.io/helm-charts
helm repo update

# =============================================================================
# CREATE TEMPORAL NAMESPACE
# =============================================================================
kubectl create namespace "${NAMESPACE}" 2>/dev/null || log_warn "Namespace ${NAMESPACE} already exists"

# =============================================================================
# GET DATABASE CONNECTION INFO
# =============================================================================
if [[ -z "${TEMPORAL_DB_URI}" ]]; then
    log_info "Getting database connection info from Secret Manager..."
    
    # Get Cloud SQL IP
    CLOUDSQL_IP=$(gcloud sql instances describe dust-postgres --format="value(ipAddresses[0].ipAddress)")
    DB_PASSWORD=$(gcloud secrets versions access latest --secret="dust-db-password")
    
    TEMPORAL_DB_HOST="${CLOUDSQL_IP}"
    TEMPORAL_DB_PORT="5432"
    TEMPORAL_DB_USER="dustapp"
    TEMPORAL_DB_PASSWORD="${DB_PASSWORD}"
else
    # Parse URI if provided
    TEMPORAL_DB_HOST=$(echo "${TEMPORAL_DB_URI}" | sed -n 's|.*@\([^:]*\):.*|\1|p')
    TEMPORAL_DB_PORT=$(echo "${TEMPORAL_DB_URI}" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')
    TEMPORAL_DB_USER=$(echo "${TEMPORAL_DB_URI}" | sed -n 's|.*//\([^:]*\):.*|\1|p')
    TEMPORAL_DB_PASSWORD=$(echo "${TEMPORAL_DB_URI}" | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')
fi

log_info "Database Host: ${TEMPORAL_DB_HOST}"

# =============================================================================
# CREATE KUBERNETES SECRETS FOR TEMPORAL
# =============================================================================
log_info "Creating Kubernetes secrets for Temporal..."

kubectl create secret generic temporal-default-store \
    --namespace="${NAMESPACE}" \
    --from-literal=password="${TEMPORAL_DB_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic temporal-visibility-store \
    --namespace="${NAMESPACE}" \
    --from-literal=password="${TEMPORAL_DB_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

# =============================================================================
# CREATE VALUES FILE FOR HELM
# =============================================================================
log_info "Creating Helm values file..."

cat > /tmp/temporal-values.yaml << EOF
# Temporal Helm Chart Values for Dust
# Self-hosted on GKE with Cloud SQL PostgreSQL backend

server:
  replicaCount: 2
  
  config:
    persistence:
      default:
        driver: "sql"
        sql:
          driver: "postgres"
          host: "${TEMPORAL_DB_HOST}"
          port: ${TEMPORAL_DB_PORT}
          database: "temporal"
          user: "${TEMPORAL_DB_USER}"
          existingSecret: "temporal-default-store"
          maxConns: 20
          maxIdleConns: 20
          maxConnLifetime: "1h"
      
      visibility:
        driver: "sql"
        sql:
          driver: "postgres"
          host: "${TEMPORAL_DB_HOST}"
          port: ${TEMPORAL_DB_PORT}
          database: "temporal_visibility"
          user: "${TEMPORAL_DB_USER}"
          existingSecret: "temporal-visibility-store"
          maxConns: 20
          maxIdleConns: 20
          maxConnLifetime: "1h"

  frontend:
    replicaCount: 2
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
  
  history:
    replicaCount: 2
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
  
  matching:
    replicaCount: 2
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
  
  worker:
    replicaCount: 1
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 250m
        memory: 256Mi

# Temporal Web UI
web:
  enabled: true
  replicaCount: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
  service:
    type: ClusterIP
    port: 8080

# Admin tools for namespace management
admintools:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 100m
      memory: 256Mi

# Disable built-in Cassandra (we use PostgreSQL)
cassandra:
  enabled: false

# Disable built-in MySQL (we use PostgreSQL)
mysql:
  enabled: false

# Disable built-in PostgreSQL (we use Cloud SQL)
postgresql:
  enabled: false

# Disable Elasticsearch for now (optional - can enable later)
elasticsearch:
  enabled: false

# Use standard visibility with PostgreSQL
schema:
  setup:
    enabled: true
  update:
    enabled: true
EOF

# =============================================================================
# DEPLOY TEMPORAL USING HELM
# =============================================================================
log_info "Deploying Temporal using Helm (this may take 5-10 minutes)..."

helm upgrade --install temporal temporal/temporal \
    --namespace="${NAMESPACE}" \
    --values=/tmp/temporal-values.yaml \
    --wait \
    --timeout=15m

# =============================================================================
# WAIT FOR TEMPORAL TO BE READY
# =============================================================================
log_info "Waiting for Temporal services to be ready..."

kubectl wait --for=condition=available deployment/temporal-frontend \
    --namespace="${NAMESPACE}" \
    --timeout=300s || log_warn "Frontend deployment not ready yet"

kubectl wait --for=condition=available deployment/temporal-history \
    --namespace="${NAMESPACE}" \
    --timeout=300s || log_warn "History deployment not ready yet"

kubectl wait --for=condition=available deployment/temporal-matching \
    --namespace="${NAMESPACE}" \
    --timeout=300s || log_warn "Matching deployment not ready yet"

kubectl wait --for=condition=available deployment/temporal-worker \
    --namespace="${NAMESPACE}" \
    --timeout=300s || log_warn "Worker deployment not ready yet"

# =============================================================================
# CREATE TEMPORAL NAMESPACES
# =============================================================================
log_info "Creating Temporal namespaces for Dust..."

# Wait for admintools pod to be ready
sleep 10

# Get admintools pod name
ADMINTOOLS_POD=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=temporal-admintools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "${ADMINTOOLS_POD}" ]]; then
    log_info "Creating Temporal namespaces using admintools..."
    
    # Create namespaces
    TEMPORAL_NAMESPACES=("dust-front" "dust-agent" "dust-connectors" "dust-relocation")
    
    for ns in "${TEMPORAL_NAMESPACES[@]}"; do
        log_info "  Creating namespace: ${ns}"
        kubectl exec -n "${NAMESPACE}" "${ADMINTOOLS_POD}" -- \
            temporal operator namespace create "${ns}" 2>/dev/null || \
            log_warn "Namespace ${ns} may already exist"
    done
else
    log_warn "Admintools pod not found. Create namespaces manually later:"
    echo ""
    echo "kubectl exec -it \$(kubectl get pods -n temporal -l app.kubernetes.io/name=temporal-admintools -o jsonpath='{.items[0].metadata.name}') -n temporal -- bash"
    echo "temporal operator namespace create dust-front"
    echo "temporal operator namespace create dust-agent"
    echo "temporal operator namespace create dust-connectors"
    echo "temporal operator namespace create dust-relocation"
fi

# =============================================================================
# OUTPUT SUMMARY
# =============================================================================
echo ""
echo "============================================================================="
log_info "Temporal Deployment Complete!"
echo "============================================================================="
echo ""
echo "Temporal Services:"
echo "  Frontend:  temporal-frontend.${NAMESPACE}.svc.cluster.local:7233"
echo "  History:   temporal-history.${NAMESPACE}.svc.cluster.local"
echo "  Matching:  temporal-matching.${NAMESPACE}.svc.cluster.local"
echo "  Worker:    temporal-worker.${NAMESPACE}.svc.cluster.local"
echo "  Web UI:    temporal-web.${NAMESPACE}.svc.cluster.local:8080"
echo ""
echo "Temporal Namespaces created:"
echo "  - dust-front"
echo "  - dust-agent"
echo "  - dust-connectors"
echo "  - dust-relocation"
echo ""
echo "============================================================================="
echo "To access Temporal Web UI locally:"
echo "  kubectl port-forward svc/temporal-web -n temporal 8080:8080"
echo "  Then open: http://localhost:8080"
echo ""
echo "============================================================================="
echo "IMPORTANT: Update your application config with:"
echo ""
echo "  # For self-hosted Temporal (instead of Temporal Cloud):"
echo "  TEMPORAL_ADDRESS=temporal-frontend.temporal.svc.cluster.local:7233"
echo "  TEMPORAL_NAMESPACE=dust-front"
echo "  TEMPORAL_AGENT_NAMESPACE=dust-agent"
echo "  TEMPORAL_CONNECTORS_NAMESPACE=dust-connectors"
echo "  TEMPORAL_RELOCATION_NAMESPACE=dust-relocation"
echo ""
echo "============================================================================="
echo "Next Steps:"
echo "  1. Run: ./04-deploy-applications.sh"
echo "============================================================================="

# Cleanup
rm -f /tmp/temporal-values.yaml
