# Dust - GCP Deployment Guide

Complete step-by-step guide to deploy Dust to Google Cloud Platform.

## Prerequisites

### Required Tools
- [Google Cloud SDK (gcloud)](https://cloud.google.com/sdk/docs/install)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Git](https://git-scm.com/)

### Required Accounts & Services
- GCP Account with billing enabled
- [Elastic Cloud](https://cloud.elastic.co) account (for managed Elasticsearch)
- [WorkOS](https://workos.com) account (for authentication)
- [SendGrid](https://sendgrid.com) account (for emails)
- [Novu](https://novu.co) account (for notifications)

### OAuth Providers (based on connectors needed)
- [Slack API](https://api.slack.com/apps) - Create a Slack app
- [Notion](https://www.notion.so/my-integrations) - Create an integration
- [Google Cloud Console](https://console.cloud.google.com) - OAuth credentials for Google Drive

---

## Deployment Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     GCP Deployment Architecture                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    GKE Cluster                           │   │
│  │  ┌─────────────────────────────────────────────────────┐ │   │
│  │  │  dust-app namespace                                 │ │   │
│  │  │  ┌─────┐ ┌─────┐ ┌──────────┐ ┌─────────────┐       │ │   │
│  │  │  │front│ │core │ │connectors│ │front-workers│       │ │   │
│  │  │  └─────┘ └─────┘ └──────────┘ └─────────────┘       │ │   │
│  │  │  ┌─────┐ ┌─────┐ ┌──────────────────────────┐       │ │   │
│  │  │  │ viz │ │oauth│ │connectors-worker         │       │ │   │
│  │  │  └─────┘ └─────┘ └──────────────────────────┘       │ │   │
│  │  └─────────────────────────────────────────────────────┘ │   │
│  │                                                          │   │
│  │  ┌─────────────────────────────────────────────────────┐ │   │
│  │  │  temporal namespace                                 │ │   │
│  │  │  ┌────────┐ ┌───────┐ ┌────────┐ ┌──────┐ ┌───┐     │ │   │
│  │  │  │frontend│ │history│ │matching│ │worker│ │web│     │ │   │
│  │  │  └────────┘ └───────┘ └────────┘ └──────┘ └───┘     │ │   │
│  │  └─────────────────────────────────────────────────────┘ │   │
│  │                                                          │   │
│  │  ┌───────────────┐  ┌──────────────┐                     │   │
│  │  │qdrant ns      │  │tika ns       │                     │   │
│  │  │ ┌──────────┐  │  │ ┌──────────┐ │                     │   │
│  │  │ │ qdrant   │  │  │ │  tika    │ │                     │   │
│  │  │ └──────────┘  │  │ └──────────┘ │                     │   │
│  │  └───────────────┘  └──────────────┘                     │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │  Cloud SQL   │  │ Memorystore  │  │  Cloud Storage       │   │
│  │  (Postgres)  │  │  (Redis)     │  │  (8 buckets)         │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ VPC Peering
                              ▼
                    ┌──────────────────┐
                    │  Elastic Cloud   │
                    │  (Elasticsearch) │
                    └──────────────────┘
```

---

## Step 1: Initial Setup

### 1.1 Clone the Repository

```bash
git clone https://github.com/your-org/dust.git
cd dust
```

### 1.2 Configure Environment Variables

```bash
# Set your project configuration
export PROJECT_ID="your-gcp-project-id"
export REGION="europe-west1"  # or us-central1
export BILLING_ACCOUNT_ID="your-billing-account-id"  # Optional

# Make scripts executable
chmod +x gcp-deployment/scripts/*.sh
```

### 1.3 Authenticate with GCP

```bash
gcloud auth login
gcloud auth application-default login
```

---

## Step 2: GCP Project Setup

Run the project setup script:

```bash
cd gcp-deployment/scripts
./01-setup-gcp-project.sh
```

This script will:
- ✅ Create or select the GCP project
- ✅ Enable required APIs
- ✅ Create Artifact Registry repository
- ✅ Create service accounts with proper IAM roles
- ✅ Create VPC network and subnets
- ✅ Allocate IP ranges for private services
- ✅ Create Cloud NAT for outbound traffic
- ✅ Create GCS buckets
- ✅ Create firewall rules

**Duration:** ~5-10 minutes

---

## Step 3: Infrastructure Deployment

Deploy GKE, Cloud SQL, and Memorystore:

```bash
./02-deploy-infrastructure.sh
```

This script will:
- ✅ Create GKE cluster with autoscaling
- ✅ Create worker node pool
- ✅ Create Cloud SQL PostgreSQL instance
- ✅ Create all required databases
- ✅ Create Memorystore Redis instance
- ✅ Create Kubernetes namespaces
- ✅ Configure Workload Identity
- ✅ Store credentials in Secret Manager

**Duration:** ~20-30 minutes

### Save Infrastructure Values

After this script completes, save the output values:
- Cloud SQL Private IP
- Redis Private IP
- Database password (stored in Secret Manager)

---

## Step 4: External Services Setup

### 4.1 Elastic Cloud

1. Go to [Elastic Cloud](https://cloud.elastic.co)
2. Create a new deployment:
   - Cloud Provider: GCP
   - Region: Same as your GKE cluster (europe-west4)
   - Plan: 2GB RAM minimum recommended
3. Save the following:
   - Elasticsearch endpoint URL
   - Username (usually `elastic`)
   - Password

### 4.2 WorkOS

1. Go to [WorkOS Dashboard](https://dashboard.workos.com)
2. Create a new application
3. Configure authentication methods
4. Save:
   - API Key
   - Client ID
   - Webhook secrets

### 4.3 OAuth Providers

#### Slack
1. Go to [Slack API Apps](https://api.slack.com/apps)
2. Create a new app
3. Configure OAuth scopes
4. Add redirect URL: `https://YOUR_DOMAIN/oauth/slack/callback`
5. Save Client ID

#### Notion
1. Go to [Notion Integrations](https://www.notion.so/my-integrations)
2. Create a new integration (public OAuth)
3. Add redirect URL: `https://YOUR_DOMAIN/oauth/notion/callback`
4. Save OAuth Client ID

#### Google Drive
1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Navigate to APIs & Services > Credentials
3. Create OAuth 2.0 Client ID (Web application)
4. Add redirect URI: `https://YOUR_DOMAIN/oauth/google/callback`
5. Enable Google Drive API
6. Save Client ID

---

## Step 5: Deploy Temporal

Deploy self-hosted Temporal to GKE:

```bash
./03-deploy-temporal.sh
```

This script will:
- ✅ Add Temporal Helm repository
- ✅ Create Temporal namespace
- ✅ Deploy Temporal with PostgreSQL backend
- ✅ Create Temporal application namespaces:
  - `dust-front`
  - `dust-agent`
  - `dust-connectors`
  - `dust-relocation`

**Duration:** ~10-15 minutes

### Verify Temporal

```bash
# Check Temporal pods
kubectl get pods -n temporal

# Access Temporal Web UI
kubectl port-forward svc/temporal-web -n temporal 8080:8080
# Open: http://localhost:8080
```

---

## Step 6: Create Kubernetes Secrets

Before deploying applications, create the secrets:

```bash
# Get Cloud SQL IP
CLOUDSQL_IP=$(gcloud sql instances describe dust-postgres --format="value(ipAddresses[0].ipAddress)")

# Get database password from Secret Manager
DB_PASSWORD=$(gcloud secrets versions access latest --secret="dust-db-password")

# Create secrets
kubectl create secret generic dust-secrets -n dust-app \
  --from-literal=FRONT_DATABASE_URI="postgresql://dustapp:${DB_PASSWORD}@${CLOUDSQL_IP}:5432/dust_front" \
  --from-literal=CONNECTORS_DATABASE_URI="postgresql://dustapp:${DB_PASSWORD}@${CLOUDSQL_IP}:5432/dust_connectors" \
  --from-literal=CORE_DATABASE_URI="postgresql://dustapp:${DB_PASSWORD}@${CLOUDSQL_IP}:5432/dust_api" \
  --from-literal=OAUTH_DATABASE_URI="postgresql://dustapp:${DB_PASSWORD}@${CLOUDSQL_IP}:5432/dust_oauth" \
  --from-literal=DATABASES_STORE_DATABASE_URI="postgresql://dustapp:${DB_PASSWORD}@${CLOUDSQL_IP}:5432/dust_databases_store" \
  --from-literal=ELASTICSEARCH_URL="YOUR_ELASTIC_CLOUD_URL" \
  --from-literal=ELASTICSEARCH_USERNAME="elastic" \
  --from-literal=ELASTICSEARCH_PASSWORD="YOUR_ELASTIC_PASSWORD" \
  --from-literal=WORKOS_API_KEY="YOUR_WORKOS_API_KEY" \
  --from-literal=WORKOS_CLIENT_ID="YOUR_WORKOS_CLIENT_ID" \
  --from-literal=WORKOS_COOKIE_PASSWORD="$(openssl rand -base64 24 | cut -c1-32)" \
  --from-literal=WORKOS_ISSUER_URL="https://api.workos.com/sso/authorize" \
  --from-literal=WORKOS_SESSION_COOKIE_DOMAIN=".yourdomain.com" \
  --from-literal=WORKOS_ENVIRONMENT_ID="YOUR_WORKOS_ENV_ID" \
  --from-literal=DUST_INVITE_TOKEN_SECRET="$(openssl rand -hex 32)" \
  --from-literal=DUST_REGISTRY_SECRET="$(openssl rand -hex 32)" \
  --from-literal=DUST_CONNECTORS_SECRET="$(openssl rand -hex 32)" \
  --from-literal=VIZ_JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=SENDGRID_API_KEY="YOUR_SENDGRID_KEY" \
  --from-literal=NOVU_SECRET_KEY="YOUR_NOVU_KEY" \
  --from-literal=OAUTH_SLACK_CLIENT_ID="YOUR_SLACK_CLIENT_ID" \
  --from-literal=OAUTH_NOTION_CLIENT_ID="YOUR_NOTION_CLIENT_ID" \
  --from-literal=OAUTH_GOOGLE_DRIVE_CLIENT_ID="YOUR_GOOGLE_CLIENT_ID"
```

See `docs/SECRETS.md` for the complete list of all required secrets.

---

## Step 7: Build & Deploy Applications

### Option A: Build images first (recommended for first deployment)

```bash
./04-deploy-applications.sh
# Answer 'y' when asked to build images
```

### Option B: Deploy with pre-built images

If images are already built (e.g., via CI/CD):

```bash
IMAGE_TAG="abc1234" ./04-deploy-applications.sh
# Answer 'n' when asked to build images
```

This script will deploy:
- ✅ Qdrant (vector database)
- ✅ Apache Tika (document extraction)
- ✅ Core API service
- ✅ OAuth service
- ✅ Connectors Web API
- ✅ Connectors Worker
- ✅ Front (Next.js app)
- ✅ Front Workers (Temporal workers)
- ✅ Viz service

**Duration:** ~10-20 minutes

---

## Step 8: Initialize Databases

Run database migrations and create indices:

```bash
./05-init-databases.sh
```

This script will:
- ✅ Run Front database migrations
- ✅ Run Connectors database migrations
- ✅ Run Core database migrations
- ✅ Create Elasticsearch indices
- ✅ Create Qdrant collections
- ✅ Initialize Dust built-in apps

**Duration:** ~5-10 minutes

---

## Step 9: Set Up External Access

### 9.1 Create Ingress

```yaml
# Create file: ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dust-ingress
  namespace: dust-app
  annotations:
    kubernetes.io/ingress.class: "gce"
    kubernetes.io/ingress.global-static-ip-name: "dust-static-ip"
    networking.gke.io/managed-certificates: "dust-certificate"
spec:
  rules:
    - host: dust.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: front
                port:
                  number: 3000
    - host: viz.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: viz
                port:
                  number: 3000
```

### 9.2 Reserve Static IP

```bash
gcloud compute addresses create dust-static-ip --global
```

### 9.3 Create Managed Certificate

```yaml
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: dust-certificate
  namespace: dust-app
spec:
  domains:
    - dust.yourdomain.com
    - viz.yourdomain.com
```

### 9.4 Configure DNS

Point your domain to the static IP:
```bash
gcloud compute addresses describe dust-static-ip --global --format="value(address)"
```

---

## Verification

### Check Deployments

```bash
kubectl get deployments -n dust-app
kubectl get pods -n dust-app
kubectl get pods -n temporal
```

### Check Logs

```bash
# Front logs
kubectl logs -f deployment/front -n dust-app

# Core logs
kubectl logs -f deployment/core -n dust-app

# Front workers logs
kubectl logs -f deployment/front-workers -n dust-app
```

### Quick Access (Port Forward)

```bash
# Access front locally
kubectl port-forward svc/front -n dust-app 3000:3000
# Open: http://localhost:3000

# Access Temporal UI
kubectl port-forward svc/temporal-web -n temporal 8080:8080
# Open: http://localhost:8080
```

---

## CI/CD Setup

### Create Cloud Build Triggers

```bash
# Connect your GitHub repository first via Cloud Console

# Core service trigger
gcloud builds triggers create github \
  --name="build-core" \
  --repository="projects/${PROJECT_ID}/locations/${REGION}/connections/github/repositories/dust" \
  --branch-pattern="^main$" \
  --build-config="gcp-deployment/cloudbuild/cloudbuild-core.yaml" \
  --included-files="core/**"

# Front service trigger
gcloud builds triggers create github \
  --name="build-front" \
  --repository="projects/${PROJECT_ID}/locations/${REGION}/connections/github/repositories/dust" \
  --branch-pattern="^main$" \
  --build-config="gcp-deployment/cloudbuild/cloudbuild-front.yaml" \
  --included-files="front/**,sdks/js/**"

# Connectors service trigger
gcloud builds triggers create github \
  --name="build-connectors" \
  --repository="projects/${PROJECT_ID}/locations/${REGION}/connections/github/repositories/dust" \
  --branch-pattern="^main$" \
  --build-config="gcp-deployment/cloudbuild/cloudbuild-connectors.yaml" \
  --included-files="connectors/**,sdks/js/**"
```

---

## Troubleshooting

### Common Issues

#### Pods not starting
```bash
kubectl describe pod <pod-name> -n dust-app
kubectl logs <pod-name> -n dust-app
```

#### Database connection issues
- Check Cloud SQL private IP is correct
- Verify VPC peering is active
- Check firewall rules allow internal traffic

#### Temporal connection issues
- Verify Temporal frontend is running
- Check namespace exists: `kubectl exec -it temporal-admintools-0 -n temporal -- temporal operator namespace list`

### Useful Commands

```bash
# Restart a deployment
kubectl rollout restart deployment/front -n dust-app

# Check secrets
kubectl get secrets -n dust-app

# View configmap
kubectl get configmap dust-config -n dust-app -o yaml

# Execute into a pod
kubectl exec -it deployment/front -n dust-app -- bash
```

---

## Cost Optimization Tips

1. **GKE Autoscaling**: Configure proper min/max nodes
2. **Cloud SQL**: Use db-custom-2-8192 for ~40 users
3. **Memorystore**: 2GB is sufficient for caching
4. **Preemptible VMs**: Consider for non-critical workloads
5. **Committed Use**: 1-year commitment for 37% savings

Estimated monthly cost: **$600-900** for ~40 users

---

## Support

- Check `docs/SECRETS.md` for environment variable reference
- Review `docs/TROUBLESHOOTING.md` for common issues
- Refer to the Dust project documentation

---

## Step 10: Deploy Firebase Webhook Router

The Firebase webhook router receives webhooks from Slack, Microsoft Teams, and Notion and forwards them to your connectors service.

### Prerequisites

```bash
# Install Firebase CLI
npm install -g firebase-tools

# Login to Firebase
firebase login

# Enable required APIs
gcloud services enable cloudfunctions.googleapis.com
gcloud services enable secretmanager.googleapis.com
```

### Create Secrets

```bash
# Create webhook secret (self-generated)
export WEBHOOK_SECRET="$(openssl rand -hex 32)"

gcloud secrets create connectors-DUST_CONNECTORS_WEBHOOKS_SECRET --replication-policy="automatic"
echo -n "$WEBHOOK_SECRET" | gcloud secrets versions add connectors-DUST_CONNECTORS_WEBHOOKS_SECRET --data-file=-

# Platform-specific secrets (get from respective platforms)
gcloud secrets create SLACK_SIGNING_SECRET --replication-policy="automatic"
gcloud secrets create MICROSOFT_BOT_ID_SECRET --replication-policy="automatic"
gcloud secrets create NOTION_SIGNING_SECRET --replication-policy="automatic"

# Add values to each secret (replace placeholders with actual values)
echo -n "your-slack-signing-secret" | gcloud secrets versions add SLACK_SIGNING_SECRET --data-file=-
echo -n "your-microsoft-bot-id" | gcloud secrets versions add MICROSOFT_BOT_ID_SECRET --data-file=-
echo -n "your-notion-signing-secret" | gcloud secrets versions add NOTION_SIGNING_SECRET --data-file=-
```

### Deploy

```bash
cd firebase-functions/webhook-router

# Build and deploy (EU region)
export GCP_GLOBAL_PROJECT_ID="your-project-id"
export GCP_EU_PROJECT_ID="your-project-id"

./deploy.sh
```

### Function URL

After deployment, your webhook endpoint will be available at:
```
https://europe-west4-your-project.cloudfunctions.net/webhookRouter/YOUR_WEBHOOK_SECRET/{platform}/{endpoint}
```

### Configure Platform Webhooks

Configure the webhook URLs in each platform's developer console:
- **Slack**: `https://europe-west4-your-project.cloudfunctions.net/webhookRouter/<WEBHOOK_SECRET>/slack/events`
- **Teams**: `https://europe-west4-your-project.cloudfunctions.net/webhookRouter/<WEBHOOK_SECRET>/microsoft/teams/messages`
- **Notion**: `https://europe-west4-your-project.cloudfunctions.net/webhookRouter/<WEBHOOK_SECRET>/notion`

### Cost

Firebase Functions free tier includes:
- 2M invocations/month
- 400K GB-seconds/month
- 200K CPU-seconds/month

For typical webhook traffic, this is usually free ($0-5/month).
