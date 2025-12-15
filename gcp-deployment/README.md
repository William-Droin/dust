# Dust - GCP Deployment

This directory contains all the necessary configuration and scripts to deploy Dust to Google Cloud Platform.

## 📁 Directory Structure

```
gcp-deployment/
├── README.md                 # This file
├── cloudbuild/               # CI/CD pipeline configurations
│   ├── cloudbuild-core.yaml
│   ├── cloudbuild-front.yaml
│   ├── cloudbuild-connectors.yaml
│   ├── cloudbuild-viz.yaml
│   └── cloudbuild-deploy.yaml
├── scripts/                  # Deployment automation scripts
│   ├── 01-setup-gcp-project.sh
│   ├── 02-deploy-infrastructure.sh
│   ├── 03-deploy-temporal.sh
│   ├── 04-deploy-applications.sh
│   └── 05-init-databases.sh
└── docs/                     # Documentation
    ├── DEPLOYMENT.md         # Step-by-step deployment guide
    └── SECRETS.md            # Environment variables reference
```

## 🚀 Quick Start

### Prerequisites

- Google Cloud SDK (`gcloud`)
- `kubectl`
- `helm`
- GCP project with billing enabled

### Deployment Steps

```bash
# 1. Set environment variables
export PROJECT_ID="your-project-id"
export REGION="europe-west1"

# 2. Make scripts executable
chmod +x scripts/*.sh

# 3. Run deployment scripts in order
cd scripts
./01-setup-gcp-project.sh      # ~5-10 min
./02-deploy-infrastructure.sh   # ~20-30 min
./03-deploy-temporal.sh         # ~10-15 min
./04-deploy-applications.sh     # ~10-20 min
./05-init-databases.sh          # ~5-10 min
```

Total deployment time: **~60-90 minutes**

## 📖 Documentation

- **[DEPLOYMENT.md](docs/DEPLOYMENT.md)** - Complete deployment guide with detailed instructions
- **[SECRETS.md](docs/SECRETS.md)** - All environment variables and secrets required

## 🏗️ Architecture Summary

| Component | GCP Service | Notes |
|-----------|-------------|-------|
| Kubernetes | GKE | Regional cluster, autoscaling |
| PostgreSQL | Cloud SQL | 7 databases |
| Redis | Memorystore | 2GB |
| Object Storage | Cloud Storage | 8 buckets |
| Container Registry | Artifact Registry | Docker images |
| Secrets | Secret Manager | All credentials |

### Self-Hosted on GKE
- Temporal (workflow orchestration)
- Qdrant (vector database)
- Apache Tika (document extraction)

### External Managed
- Elasticsearch (Elastic Cloud)
- Authentication (WorkOS)

## 💰 Estimated Monthly Cost

| Resource | Specification | Est. Cost |
|----------|---------------|-----------|
| GKE | 3-5 e2-standard-4 nodes | $300-500 |
| Cloud SQL | db-custom-2-8192 | $100-150 |
| Memorystore | 2GB Basic | $50 |
| Cloud Storage | ~50GB | $5 |
| Elastic Cloud | 2GB RAM | $100 |
| Networking | NAT, LB | $50-100 |
| **Total** | | **$600-900/mo** |

## 🔧 CI/CD

Cloud Build triggers are configured to:
- Build images on push to `main` branch
- Store images in Artifact Registry
- Deploy via manual trigger

To set up triggers:
```bash
# See docs/DEPLOYMENT.md for detailed instructions
gcloud builds triggers create github --name="build-front" ...
```

## ⚠️ Important Notes

1. **Temporal Configuration**: The original Dust code uses Temporal Cloud. For self-hosted, you may need to modify:
   - `front/lib/temporal.ts`
   - `connectors/src/lib/temporal.ts`
   
   Change the connection from `tmprl.cloud:7233` to internal GKE service.

2. **Secrets**: All secrets must be created manually before deploying applications. See `docs/SECRETS.md`.

3. **Domain & SSL**: After deployment, configure Ingress and SSL certificates for external access.

## 🆘 Support

If you encounter issues:
1. Check pod logs: `kubectl logs -f deployment/<name> -n dust-app`
2. Describe pods: `kubectl describe pod <name> -n dust-app`
3. Review `docs/DEPLOYMENT.md#troubleshooting`
