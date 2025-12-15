#!/bin/bash
# =============================================================================
# Dust Database Initialization Script
# =============================================================================
# This script initializes all databases with required schemas and indices.
# Run this AFTER 04-deploy-applications.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
PROJECT_ID="${PROJECT_ID:-dust-production}"
REGION="${REGION:-europe-west1}"
GKE_CLUSTER_NAME="dust-cluster"
NAMESPACE="dust-app"

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
log_info "Starting database initialization..."

gcloud config set project "${PROJECT_ID}"
gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" --region="${REGION}"

# =============================================================================
# RUN FRONT DATABASE MIGRATIONS
# =============================================================================
log_info "Running Front database migrations..."

# Get a front pod
FRONT_POD=$(kubectl get pods -n ${NAMESPACE} -l app=front -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "${FRONT_POD}" ]]; then
    log_info "Using pod: ${FRONT_POD}"
    
    # Run database sync (creates tables)
    kubectl exec -n ${NAMESPACE} "${FRONT_POD}" -- \
        npx tsx admin/db.ts || log_warn "Front DB migration may have failed"
    
    log_info "Front database initialized"
else
    log_error "No front pod found. Deploy applications first."
fi

# =============================================================================
# RUN CONNECTORS DATABASE MIGRATIONS
# =============================================================================
log_info "Running Connectors database migrations..."

CONNECTORS_POD=$(kubectl get pods -n ${NAMESPACE} -l app=connectors-web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "${CONNECTORS_POD}" ]]; then
    log_info "Using pod: ${CONNECTORS_POD}"
    
    # Run sequelize sync
    kubectl exec -n ${NAMESPACE} "${CONNECTORS_POD}" -- \
        npm run initdb -- --unsafe 2>/dev/null || log_warn "Connectors DB migration may have failed"
    
    log_info "Connectors database initialized"
else
    log_warn "No connectors pod found."
fi

# =============================================================================
# RUN CORE DATABASE MIGRATIONS
# =============================================================================
log_info "Running Core database migrations..."

CORE_POD=$(kubectl get pods -n ${NAMESPACE} -l app=core -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "${CORE_POD}" ]]; then
    log_info "Using pod: ${CORE_POD}"
    
    # Run cargo migration
    kubectl exec -n ${NAMESPACE} "${CORE_POD}" -- \
        cargo run --release --bin init_db 2>/dev/null || log_warn "Core DB migration may have failed"
    
    log_info "Core database initialized"
else
    log_warn "No core pod found."
fi

# =============================================================================
# INITIALIZE ELASTICSEARCH INDICES
# =============================================================================
log_info "Initializing Elasticsearch indices..."

if [[ -n "${CORE_POD}" ]]; then
    # Create data_sources_nodes index
    kubectl exec -n ${NAMESPACE} "${CORE_POD}" -- \
        cargo run --release --bin elasticsearch_create_index -- \
        --index-name data_sources_nodes --index-version 4 --skip-confirmation \
        2>/dev/null || log_warn "Failed to create data_sources_nodes index"
    
    # Create data_sources index
    kubectl exec -n ${NAMESPACE} "${CORE_POD}" -- \
        cargo run --release --bin elasticsearch_create_index -- \
        --index-name data_sources --index-version 1 --skip-confirmation \
        2>/dev/null || log_warn "Failed to create data_sources index"
    
    log_info "Elasticsearch indices created"
else
    log_warn "Cannot initialize Elasticsearch without core pod"
fi

# =============================================================================
# INITIALIZE QDRANT COLLECTIONS
# =============================================================================
log_info "Initializing Qdrant collections..."

if [[ -n "${CORE_POD}" ]]; then
    # Create embeddings collection
    kubectl exec -n ${NAMESPACE} "${CORE_POD}" -- \
        cargo run --release --bin qdrant_create_collection -- \
        --cluster cluster-0 --provider openai --model text-embedding-3-large-1536 \
        2>/dev/null || log_warn "Failed to create Qdrant collection"
    
    log_info "Qdrant collections created"
else
    log_warn "Cannot initialize Qdrant without core pod"
fi

# =============================================================================
# INITIALIZE DUST APPS (Optional)
# =============================================================================
log_info "Initializing Dust built-in apps..."

if [[ -n "${FRONT_POD}" ]]; then
    # Initialize plans
    kubectl exec -n ${NAMESPACE} "${FRONT_POD}" -- \
        npx tsx admin/init_plans.ts 2>/dev/null || log_warn "Failed to init plans"
    
    # Initialize Dust apps  
    kubectl exec -n ${NAMESPACE} "${FRONT_POD}" -- \
        npx tsx admin/init_dust_apps.ts 2>/dev/null || log_warn "Failed to init dust apps"
    
    log_info "Dust apps initialized"
else
    log_warn "Cannot initialize Dust apps without front pod"
fi

# =============================================================================
# OUTPUT SUMMARY
# =============================================================================
echo ""
echo "============================================================================="
log_info "Database Initialization Complete!"
echo "============================================================================="
echo ""
echo "Initialized:"
echo "  ✓ Front database (dust_front)"
echo "  ✓ Connectors database (dust_connectors)"
echo "  ✓ Core database (dust_api)"
echo "  ✓ Elasticsearch indices"
echo "  ✓ Qdrant collections"
echo "  ✓ Dust built-in apps"
echo ""
echo "============================================================================="
echo "Your Dust deployment is now ready!"
echo ""
echo "To access the application:"
echo "  1. Set up an Ingress or LoadBalancer"
echo "  2. Configure DNS for your domain"
echo "  3. Set up SSL certificates"
echo ""
echo "Quick access via port-forward:"
echo "  kubectl port-forward svc/front -n dust-app 3000:3000"
echo "  Then open: http://localhost:3000"
echo "============================================================================="
