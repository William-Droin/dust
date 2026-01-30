#!/bin/bash
# =============================================================================
# Dust Infrastructure Deployment Script
# =============================================================================
# This script deploys the core infrastructure: GKE, Cloud SQL, Memorystore
# Run this AFTER 01-setup-gcp-project.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - EDIT THESE VALUES
# =============================================================================

REGION="${REGION:-europe-west4}"
ZONE="${ZONE:-europe-west4-b}"

# GKE Configuration
GKE_CLUSTER_NAME="dust-cluster"
GKE_VERSION="1.29"  # Check available versions: gcloud container get-server-config --region=REGION
GKE_MACHINE_TYPE="e2-standard-2"  # 2 vCPUs, 8GB RAM
GKE_MIN_NODES="1"
GKE_MAX_NODES="1"

# Cloud SQL Configuration
CLOUDSQL_INSTANCE_NAME="dust-postgres"
CLOUDSQL_TIER="db-f1-micro"
CLOUDSQL_STORAGE_SIZE="10"  # GB
CLOUDSQL_VERSION="POSTGRES_14"

# Memorystore Configuration
REDIS_INSTANCE_NAME="dust-redis"
REDIS_MEMORY_SIZE="2"  # GB

# Service Account
SA_GKE_NODES="dust-gke-nodes"
SA_WORKLOAD_IDENTITY="dust-workload-identity"

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
log_info "Starting infrastructure deployment..."

gcloud config set project "${PROJECT_ID}"

# =============================================================================
# DEPLOY GKE CLUSTER
# =============================================================================
log_info "Checking GKE cluster..."

if gcloud container clusters describe "${GKE_CLUSTER_NAME}" --region="${REGION}" &> /dev/null; then
    log_info "GKE cluster '${GKE_CLUSTER_NAME}' already exists"
else
    log_info "Creating GKE cluster '${GKE_CLUSTER_NAME}' (this takes 10-15 minutes)..."
    
    gcloud container clusters create "${GKE_CLUSTER_NAME}" \
        --region="${REGION}" \
        --num-nodes=1 \
        --machine-type="${GKE_MACHINE_TYPE}" \
        --network="dust-vpc" \
        --subnetwork="dust-subnet" \
        --cluster-secondary-range-name="gke-pods" \
        --services-secondary-range-name="gke-services" \
        --enable-ip-alias \
        --enable-autoscaling \
        --min-nodes="${GKE_MIN_NODES}" \
        --max-nodes="${GKE_MAX_NODES}" \
        --enable-autorepair \
        --enable-autoupgrade \
        --workload-pool="${PROJECT_ID}.svc.id.goog" \
        --service-account="${SA_GKE_NODES}@${PROJECT_ID}.iam.gserviceaccount.com" \
        --release-channel="regular" \
        --disk-size="100" \
        --disk-type="pd-ssd" \
        --logging=SYSTEM,WORKLOAD \
        --monitoring=SYSTEM
fi

# Get GKE credentials
log_info "Getting GKE credentials..."
gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" --region="${REGION}"

# =============================================================================
# CREATE ADDITIONAL NODE POOLS
# =============================================================================
log_info "Checking for worker node pool..."

if gcloud container node-pools describe workers --cluster="${GKE_CLUSTER_NAME}" --region="${REGION}" &> /dev/null; then
    log_info "Node pool 'workers' already exists"
else
    log_info "Creating worker node pool for Temporal workers..."
    
    gcloud container node-pools create workers \
        --cluster="${GKE_CLUSTER_NAME}" \
        --region="${REGION}" \
        --num-nodes=1 \
        --machine-type="e2-standard-2" \
        --enable-autoscaling \
        --min-nodes=1 \
        --max-nodes=3 \
        --service-account="${SA_GKE_NODES}@${PROJECT_ID}.iam.gserviceaccount.com" \
        --node-labels="workload=workers" \
        --node-taints="workload=workers:NoSchedule"
fi

# =============================================================================
# DEPLOY CLOUD SQL (PostgreSQL)
# =============================================================================
log_info "Checking Cloud SQL instance..."

if gcloud sql instances describe "${CLOUDSQL_INSTANCE_NAME}" &> /dev/null; then
    log_info "Cloud SQL instance '${CLOUDSQL_INSTANCE_NAME}' already exists"
else
    log_info "Creating Cloud SQL instance '${CLOUDSQL_INSTANCE_NAME}' (this takes 10-15 minutes)..."
    
    gcloud sql instances create "${CLOUDSQL_INSTANCE_NAME}" \
        --database-version="${CLOUDSQL_VERSION}" \
        --tier="${CLOUDSQL_TIER}" \
        --region="${REGION}" \
        --storage-size="${CLOUDSQL_STORAGE_SIZE}" \
        --storage-type="SSD" \
        --storage-auto-increase \
        --backup-start-time="02:00" \
        --enable-point-in-time-recovery \
        --network="projects/${PROJECT_ID}/global/networks/dust-vpc" \
        --no-assign-ip \
        --database-flags="max_connections=200,log_min_duration_statement=1000"
fi

# Generate password for dustapp user
DUSTAPP_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)

# Create database user
log_info "Creating database user 'dustapp'..."
gcloud sql users create dustapp \
    --instance="${CLOUDSQL_INSTANCE_NAME}" \
    --password="${DUSTAPP_PASSWORD}" 2>/dev/null || log_warn "User may already exist"

# Create databases
log_info "Creating PostgreSQL databases..."
DATABASES=(
    "dust_front"
    "dust_connectors"
    "dust_api"
    "dust_oauth"
    "dust_databases_store"
    "temporal"
    "temporal_visibility"
)

for db in "${DATABASES[@]}"; do
    log_info "  Creating database: ${db}"
    gcloud sql databases create "${db}" \
        --instance="${CLOUDSQL_INSTANCE_NAME}" 2>/dev/null || log_warn "Database ${db} may already exist"
done

# Get Cloud SQL private IP
CLOUDSQL_IP=$(gcloud sql instances describe "${CLOUDSQL_INSTANCE_NAME}" \
    --format="value(ipAddresses[0].ipAddress)")
log_info "Cloud SQL Private IP: ${CLOUDSQL_IP}"

# =============================================================================
# DEPLOY MEMORYSTORE (Redis)
# =============================================================================
log_info "Checking Memorystore Redis instance..."

if gcloud redis instances describe "${REDIS_INSTANCE_NAME}" --region="${REGION}" &> /dev/null; then
    log_info "Redis instance '${REDIS_INSTANCE_NAME}' already exists"
else
    log_info "Creating Redis instance '${REDIS_INSTANCE_NAME}' (this takes 5-10 minutes)..."
    
    gcloud redis instances create "${REDIS_INSTANCE_NAME}" \
        --region="${REGION}" \
        --size="${REDIS_MEMORY_SIZE}" \
        --network="projects/${PROJECT_ID}/global/networks/dust-vpc" \
        --connect-mode="PRIVATE_SERVICE_ACCESS" \
        --redis-version="redis_7_0"
fi

# Get Redis IP
REDIS_IP=$(gcloud redis instances describe "${REDIS_INSTANCE_NAME}" \
    --region="${REGION}" \
    --format="value(host)")
log_info "Redis Private IP: ${REDIS_IP}"

# =============================================================================
# CREATE KUBERNETES NAMESPACES
# =============================================================================
log_info "Creating Kubernetes namespaces..."

kubectl create namespace dust-app 2>/dev/null || log_warn "Namespace dust-app already exists"
kubectl create namespace temporal 2>/dev/null || log_warn "Namespace temporal already exists"
kubectl create namespace qdrant 2>/dev/null || log_warn "Namespace qdrant already exists"
kubectl create namespace tika 2>/dev/null || log_warn "Namespace tika already exists"

# =============================================================================
# CONFIGURE WORKLOAD IDENTITY
# =============================================================================
log_info "Configuring Workload Identity..."

# Bind Kubernetes Service Account to GCP Service Account
kubectl create serviceaccount dust-app-sa -n dust-app 2>/dev/null || true

gcloud iam service-accounts add-iam-policy-binding \
    "${SA_WORKLOAD_IDENTITY}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[dust-app/dust-app-sa]" \
    --quiet || true

kubectl annotate serviceaccount dust-app-sa \
    -n dust-app \
    iam.gke.io/gcp-service-account="899703110100-compute@developer.gserviceaccount.com" \
    --overwrite

# =============================================================================
# STORE SECRETS IN SECRET MANAGER
# =============================================================================
log_info "Storing database credentials in Secret Manager..."

# Store dustapp password
echo -n "${DUSTAPP_PASSWORD}" | gcloud secrets create dust-db-password --data-file=- 2>/dev/null || \
    (echo -n "${DUSTAPP_PASSWORD}" | gcloud secrets versions add dust-db-password --data-file=-)

# Store connection strings
for db in "${DATABASES[@]}"; do
    SECRET_NAME="dust-${db//_/-}-uri"
    CONNECTION_STRING="postgresql://dustapp:${DUSTAPP_PASSWORD}@${CLOUDSQL_IP}:5432/${db}"
    
    echo -n "${CONNECTION_STRING}" | gcloud secrets create "${SECRET_NAME}" --data-file=- 2>/dev/null || \
        (echo -n "${CONNECTION_STRING}" | gcloud secrets versions add "${SECRET_NAME}" --data-file=-)
done

# Store Redis URI
echo -n "redis://${REDIS_IP}:6379" | gcloud secrets create dust-redis-uri --data-file=- 2>/dev/null || \
    (echo -n "redis://${REDIS_IP}:6379" | gcloud secrets versions add dust-redis-uri --data-file=-)

# =============================================================================
# OUTPUT SUMMARY
# =============================================================================
echo ""
echo "============================================================================="
log_info "Infrastructure Deployment Complete!"
echo "============================================================================="
echo ""
echo "GKE Cluster:"
echo "  Name:     ${GKE_CLUSTER_NAME}"
echo "  Region:   ${REGION}"
echo "  Nodes:    ${GKE_MIN_NODES}-${GKE_MAX_NODES}"
echo ""
echo "Cloud SQL (PostgreSQL):"
echo "  Instance: ${CLOUDSQL_INSTANCE_NAME}"
echo "  IP:       ${CLOUDSQL_IP}"
echo "  Username: dustapp"
echo "  Password: Stored in Secret Manager (dust-db-password)"
echo ""
echo "Databases created:"
for db in "${DATABASES[@]}"; do
    echo "  - ${db}"
done
echo ""
echo "Memorystore (Redis):"
echo "  Instance: ${REDIS_INSTANCE_NAME}"
echo "  IP:       ${REDIS_IP}"
echo ""
echo "Kubernetes Namespaces:"
echo "  - dust-app (applications)"
echo "  - temporal (workflow orchestration)"
echo "  - qdrant (vector database)"
echo "  - tika (document extraction)"
echo ""
echo "============================================================================="
echo "IMPORTANT: Save these values for your secrets configuration!"
echo ""
echo "Database Connection String Template:"
echo "  postgresql://dustapp:<password>@${CLOUDSQL_IP}:5432/<database>"
echo ""
echo "Redis Connection String:"
echo "  redis://${REDIS_IP}:6379"
echo ""
echo "============================================================================="
echo "Next Steps:"
echo "  1. Run: ./03-deploy-temporal.sh"
echo "  2. Set up Elastic Cloud and get credentials"
echo "  3. Configure OAuth providers (Slack, Notion, Google Drive)"
echo "============================================================================="
