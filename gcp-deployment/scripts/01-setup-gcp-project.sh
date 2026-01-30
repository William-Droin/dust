#!/bin/bash
# =============================================================================
# Dust GCP Project Setup Script
# =============================================================================
# This script sets up a new GCP project for Dust deployment.
# Run this first before any other deployment scripts.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - EDIT THESE VALUES
# =============================================================================

REGION="${REGION:-europe-west4}"
ZONE="${ZONE:-europe-west4-a}"
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-}"  # Optional: your billing account ID

# Service Account names
SA_GKE_NODES="dust-gke-nodes"
SA_WORKLOAD_IDENTITY="dust-workload-identity"

# =============================================================================
# COLORS FOR OUTPUT
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
log_info "Starting GCP project setup for Dust..."

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    log_error "gcloud CLI is not installed. Please install it first."
    log_error "Visit: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Check if user is authenticated
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1 > /dev/null 2>&1; then
    log_error "Not authenticated with gcloud. Please run: gcloud auth login"
    exit 1
fi

log_info "Using project: ${PROJECT_ID}"
log_info "Using region: ${REGION}"

# =============================================================================
# CREATE OR SELECT PROJECT
# =============================================================================
log_info "Setting up GCP project..."

# Check if project exists
if gcloud projects describe "${PROJECT_ID}" &> /dev/null; then
    log_info "Project ${PROJECT_ID} already exists, selecting it..."
else
    log_info "Creating new project: ${PROJECT_ID}"
    gcloud projects create "${PROJECT_ID}"
fi

# Set project as default
gcloud config set project "${PROJECT_ID}"

# Link billing account if provided
if [[ -n "${BILLING_ACCOUNT_ID}" ]]; then
    log_info "Linking billing account..."
    gcloud billing projects link "${PROJECT_ID}" --billing-account="${BILLING_ACCOUNT_ID}"
else
    log_warn "No billing account specified. Please link one manually or set BILLING_ACCOUNT_ID env var."
fi

# =============================================================================
# ENABLE REQUIRED APIS
# =============================================================================
log_info "Enabling required GCP APIs (this may take a few minutes)..."

APIS=(
    # Compute & Kubernetes
    "compute.googleapis.com"
    "container.googleapis.com"
    
    # Database & Storage
    "sqladmin.googleapis.com"
    "redis.googleapis.com"
    "storage.googleapis.com"
    
    # CI/CD & Artifacts
    "cloudbuild.googleapis.com"
    "artifactregistry.googleapis.com"
    
    # Secrets & IAM
    "secretmanager.googleapis.com"
    "iam.googleapis.com"
    "iamcredentials.googleapis.com"
    
    # Networking
    "servicenetworking.googleapis.com"
    "dns.googleapis.com"
    
    # Monitoring
    "monitoring.googleapis.com"
    "logging.googleapis.com"
    "cloudtrace.googleapis.com"
)

for api in "${APIS[@]}"; do
    log_info "  Enabling ${api}..."
    gcloud services enable "${api}" --quiet || log_warn "Failed to enable ${api}, may already be enabled"
done

# =============================================================================
# CREATE ARTIFACT REGISTRY REPOSITORY
# =============================================================================
log_info "Creating Artifact Registry repository..."

if gcloud artifacts repositories describe dust-images --location="${REGION}" &> /dev/null; then
    log_info "Artifact Registry repository 'dust-images' already exists"
else
    gcloud artifacts repositories create dust-images \
        --repository-format=docker \
        --location="${REGION}" \
        --description="Docker images for Dust application"
fi

# =============================================================================
# CREATE SERVICE ACCOUNTS
# =============================================================================
log_info "Creating service accounts..."

# GKE Node Service Account
if gcloud iam service-accounts describe "${SA_GKE_NODES}@${PROJECT_ID}.iam.gserviceaccount.com" &> /dev/null; then
    log_info "Service account ${SA_GKE_NODES} already exists"
else
    gcloud iam service-accounts create "${SA_GKE_NODES}" \
        --display-name="Dust GKE Node Service Account" \
        --description="Service account for GKE nodes"
fi

# Workload Identity Service Account
if gcloud iam service-accounts describe "${SA_WORKLOAD_IDENTITY}@${PROJECT_ID}.iam.gserviceaccount.com" &> /dev/null; then
    log_info "Service account ${SA_WORKLOAD_IDENTITY} already exists"
else
    gcloud iam service-accounts create "${SA_WORKLOAD_IDENTITY}" \
        --display-name="Dust Workload Identity Service Account" \
        --description="Service account for Workload Identity"
fi

# =============================================================================
# GRANT IAM ROLES
# =============================================================================
log_info "Granting IAM roles to service accounts..."

# GKE Node SA roles
GKE_NODE_ROLES=(
    "roles/logging.logWriter"
    "roles/monitoring.metricWriter"
    "roles/monitoring.viewer"
    "roles/artifactregistry.reader"
)

for role in "${GKE_NODE_ROLES[@]}"; do
    log_info "  Granting ${role} to GKE nodes SA..."
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA_GKE_NODES}@${PROJECT_ID}.iam.gserviceaccount.com" \
        --role="${role}" \
        --quiet || true
done

# Workload Identity SA roles
WORKLOAD_IDENTITY_ROLES=(
    "roles/storage.admin"
    "roles/secretmanager.secretAccessor"
    "roles/cloudsql.client"
)

for role in "${WORKLOAD_IDENTITY_ROLES[@]}"; do
    log_info "  Granting ${role} to Workload Identity SA..."
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA_WORKLOAD_IDENTITY}@${PROJECT_ID}.iam.gserviceaccount.com" \
        --role="${role}" \
        --quiet || true
done

# =============================================================================
# CREATE VPC NETWORK
# =============================================================================
log_info "Creating VPC network..."

if gcloud compute networks describe dust-vpc &> /dev/null; then
    log_info "VPC network 'dust-vpc' already exists"
else
    gcloud compute networks create dust-vpc \
        --subnet-mode=custom \
        --bgp-routing-mode=regional
fi

# Create subnet
if gcloud compute networks subnets describe dust-subnet --region="${REGION}" &> /dev/null; then
    log_info "Subnet 'dust-subnet' already exists"
else
    gcloud compute networks subnets create dust-subnet \
        --network=dust-vpc \
        --region="${REGION}" \
        --range=10.0.0.0/20 \
        --secondary-range=gke-pods=10.4.0.0/14,gke-services=10.8.0.0/20
fi

# =============================================================================
# ALLOCATE IP RANGE FOR PRIVATE SERVICES
# =============================================================================
log_info "Allocating IP range for private services (Cloud SQL, Memorystore)..."

if gcloud compute addresses describe dust-private-services --global &> /dev/null; then
    log_info "Private services IP range already allocated"
else
    gcloud compute addresses create dust-private-services \
        --global \
        --purpose=VPC_PEERING \
        --addresses=10.128.0.0 \
        --prefix-length=16 \
        --network=dust-vpc
fi

# Create private connection Already ran by vincent
# log_info "Creating private connection to Google services..."
# gcloud services vpc-peerings connect \
#     --service=servicenetworking.googleapis.com \
#     --ranges=dust-private-services \
#     --network=dust-vpc \
#     --project="${PROJECT_ID}" || log_warn "Private connection may already exist"

# =============================================================================
# CREATE CLOUD NAT
# =============================================================================
log_info "Creating Cloud NAT for outbound internet access..."

if gcloud compute routers describe dust-router --region="${REGION}" &> /dev/null; then
    log_info "Router 'dust-router' already exists"
else
    gcloud compute routers create dust-router \
        --network=dust-vpc \
        --region="${REGION}"
fi

if gcloud compute routers nats describe dust-nat --router=dust-router --region="${REGION}" &> /dev/null; then
    log_info "NAT 'dust-nat' already exists"
else
    gcloud compute routers nats create dust-nat \
        --router=dust-router \
        --region="${REGION}" \
        --nat-all-subnet-ip-ranges \
        --auto-allocate-nat-external-ips
fi

# =============================================================================
# CREATE GCS BUCKETS
# =============================================================================
log_info "Creating GCS buckets..."

BUCKETS=(
    "dust-${PROJECT_ID}-uploads"
    "dust-${PROJECT_ID}-private-uploads"
    "dust-${PROJECT_ID}-upsert-queue"
    "dust-${PROJECT_ID}-data-sources"
    "dust-${PROJECT_ID}-webhook-requests"
    "dust-${PROJECT_ID}-llm-traces"
    "dust-${PROJECT_ID}-tables"
    "dust-${PROJECT_ID}-relocation"
)

for bucket in "${BUCKETS[@]}"; do
    if gsutil ls -b "gs://${bucket}" &> /dev/null; then
        log_info "Bucket ${bucket} already exists"
    else
        log_info "Creating bucket: ${bucket}"
        gsutil mb -l "${REGION}" "gs://${bucket}" || log_warn "Failed to create bucket ${bucket}"
    fi
done

# =============================================================================
# CREATE FIREWALL RULES
# =============================================================================
log_info "Creating firewall rules..."

# Allow internal communication
if gcloud compute firewall-rules describe dust-allow-internal &> /dev/null; then
    log_info "Firewall rule 'dust-allow-internal' already exists"
else
    gcloud compute firewall-rules create dust-allow-internal \
        --network=dust-vpc \
        --allow=tcp,udp,icmp \
        --source-ranges=10.0.0.0/8
fi

# Allow health checks from GCP
if gcloud compute firewall-rules describe dust-allow-health-checks &> /dev/null; then
    log_info "Firewall rule 'dust-allow-health-checks' already exists"
else
    gcloud compute firewall-rules create dust-allow-health-checks \
        --network=dust-vpc \
        --allow=tcp \
        --source-ranges=130.211.0.0/22,35.191.0.0/16
fi

# =============================================================================
# OUTPUT SUMMARY
# =============================================================================
echo ""
echo "============================================================================="
log_info "GCP Project Setup Complete!"
echo "============================================================================="
echo ""
echo "Project ID:     ${PROJECT_ID}"
echo "Region:         ${REGION}"
echo "VPC Network:    dust-vpc"
echo "Subnet:         dust-subnet"
echo ""
echo "Service Accounts:"
echo "  - ${SA_GKE_NODES}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "  - ${SA_WORKLOAD_IDENTITY}@${PROJECT_ID}.iam.gserviceaccount.com"
echo ""
echo "GCS Buckets created:"
for bucket in "${BUCKETS[@]}"; do
    echo "  - gs://${bucket}"
done
echo ""
echo "============================================================================="
echo "Next Steps:"
echo "  1. Run: ./02-deploy-infrastructure.sh"
echo "============================================================================="
