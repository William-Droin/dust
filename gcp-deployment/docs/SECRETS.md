# Dust - Secrets & Environment Variables Documentation

This document lists ALL secrets and environment variables required to deploy Dust to Google Cloud Platform.

## Table of Contents
1. [Database Configuration](#database-configuration)
2. [Temporal Configuration](#temporal-configuration)
3. [Infrastructure Services](#infrastructure-services)
4. [Google Cloud Storage](#google-cloud-storage)
5. [Authentication (WorkOS)](#authentication-workos)
6. [OAuth Provider Credentials](#oauth-provider-credentials)
7. [External APIs](#external-apis)
8. [Application Configuration](#application-configuration)
9. [Monitoring & Observability](#monitoring--observability)

---

## Database Configuration

### PostgreSQL Connection Strings

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `FRONT_DATABASE_URI` | front, front-workers | ✅ | PostgreSQL connection for front service |
| `FRONT_DATABASE_READ_REPLICA_URI` | front | ❌ | Read replica for front (optional, defaults to primary) |
| `CONNECTORS_DATABASE_URI` | connectors | ✅ | PostgreSQL connection for connectors service |
| `CONNECTORS_DATABASE_READ_REPLICA_URI` | connectors | ❌ | Read replica for connectors |
| `CORE_DATABASE_URI` | core | ✅ | PostgreSQL connection for core API |
| `CORE_DATABASE_READ_REPLICA_URI` | core | ❌ | Read replica for core |
| `OAUTH_DATABASE_URI` | oauth | ✅ | PostgreSQL connection for OAuth service |
| `DATABASES_STORE_DATABASE_URI` | sqlite-worker | ✅ | PostgreSQL connection for SQLite worker |

**Format**: `postgresql://username:password@host:5432/database_name`

**Example** (Cloud SQL with private IP):
```
postgresql://dustapp:SecurePassword123!@10.0.0.5:5432/dust_front
```

**Where to get**: Created during Cloud SQL setup. Password should be generated and stored in Secret Manager.

---

## Temporal Configuration

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `TEMPORAL_NAMESPACE` | front, front-workers | ✅ | Main Temporal namespace for front workers |
| `TEMPORAL_AGENT_NAMESPACE` | front-workers | ✅ | Temporal namespace for agent loop workers |
| `TEMPORAL_CONNECTORS_NAMESPACE` | connectors-workers | ✅ | Temporal namespace for connector workers |
| `TEMPORAL_RELOCATION_NAMESPACE` | front-workers | ✅ | Temporal namespace for relocation workflows |
| `TEMPORAL_CERT_PATH` | all workers | ❌ | Path to TLS cert (not needed for self-hosted) |
| `TEMPORAL_CERT_KEY_PATH` | all workers | ❌ | Path to TLS key (not needed for self-hosted) |

**For Self-Hosted Temporal** (GKE), these namespaces need to be created:
```bash
# After Temporal is deployed, create namespaces:
kubectl exec -it temporal-admintools-0 -n temporal -- \
  temporal operator namespace create dust-front
kubectl exec -it temporal-admintools-0 -n temporal -- \
  temporal operator namespace create dust-agent
kubectl exec -it temporal-admintools-0 -n temporal -- \
  temporal operator namespace create dust-connectors
kubectl exec -it temporal-admintools-0 -n temporal -- \
  temporal operator namespace create dust-relocation
```

**Example values**:
```
TEMPORAL_NAMESPACE=dust-front
TEMPORAL_AGENT_NAMESPACE=dust-agent
TEMPORAL_CONNECTORS_NAMESPACE=dust-connectors
TEMPORAL_RELOCATION_NAMESPACE=dust-relocation
```

---

## Infrastructure Services

### Elasticsearch (Elastic Cloud)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `ELASTICSEARCH_URL` | core, front | ✅ | Elasticsearch endpoint URL |
| `ELASTICSEARCH_USERNAME` | core, front | ✅ | Elasticsearch username |
| `ELASTICSEARCH_PASSWORD` | core, front | ✅ | Elasticsearch password |

**Where to get**: 
1. Go to [Elastic Cloud](https://cloud.elastic.co)
2. Create a deployment in your preferred region (GCP europe-west1 recommended)
3. Copy the Elasticsearch endpoint and credentials

**Example**:
```
ELASTICSEARCH_URL=https://my-deployment.es.europe-west1.gcp.cloud.es.io:9243
ELASTICSEARCH_USERNAME=elastic
ELASTICSEARCH_PASSWORD=xxxxxxxxxxxxxxxx
```

### Qdrant (Self-Hosted)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `QDRANT_CLUSTER_0_URL` | core | ✅ | Qdrant cluster endpoint |
| `QDRANT_CLUSTER_0_API_KEY` | core | ❌ | Qdrant API key (optional if internal) |

**Example** (Internal GKE):
```
QDRANT_CLUSTER_0_URL=http://qdrant.qdrant.svc.cluster.local:6334
QDRANT_CLUSTER_0_API_KEY=null
```

### Redis (Memorystore)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `REDIS_URI` | front, connectors | ✅ | Redis connection for rate limiting |
| `REDIS_CACHE_URI` | front | ✅ | Redis connection for caching |

**Where to get**: Created during Memorystore setup in GCP.

**Example**:
```
REDIS_URI=redis://10.0.0.10:6379
REDIS_CACHE_URI=redis://10.0.0.10:6379
```

### Apache Tika

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `TEXT_EXTRACTION_URL` | front, connectors | ✅ | Apache Tika service URL |

**Example** (Internal GKE):
```
TEXT_EXTRACTION_URL=http://tika.tika.svc.cluster.local:9998
```

---

## Google Cloud Storage

All GCS buckets should be created in your GCP project.

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `SERVICE_ACCOUNT` | all | ✅ | GCP Service Account JSON (base64 encoded) |
| `GCP_PROJECT_ID` | all | ✅ | GCP Project ID |
| `DUST_UPLOAD_BUCKET` | front | ✅ | Public file uploads |
| `DUST_PRIVATE_UPLOADS_BUCKET` | front | ✅ | Private file uploads |
| `DUST_UPSERT_QUEUE_BUCKET` | front, front-workers | ✅ | Upsert queue storage |
| `DUST_DATA_SOURCES_BUCKET` | front, core | ✅ | Data sources storage |
| `DUST_WEBHOOK_REQUESTS_BUCKET` | front | ✅ | Webhook request logs |
| `DUST_LLM_TRACES_BUCKET` | front | ✅ | LLM trace logs |
| `DUST_TABLES_BUCKET` | front | ✅ | Tables data storage |
| `DUST_RELOCATION_BUCKET` | front-workers | ✅ | Workspace relocation data |

**Bucket naming convention**:
```
DUST_UPLOAD_BUCKET=dust-prod-uploads
DUST_PRIVATE_UPLOADS_BUCKET=dust-prod-private-uploads
DUST_UPSERT_QUEUE_BUCKET=dust-prod-upsert-queue
DUST_DATA_SOURCES_BUCKET=dust-prod-data-sources
DUST_WEBHOOK_REQUESTS_BUCKET=dust-prod-webhook-requests
DUST_LLM_TRACES_BUCKET=dust-prod-llm-traces
DUST_TABLES_BUCKET=dust-prod-tables
DUST_RELOCATION_BUCKET=dust-prod-relocation
```

**Note**: With Workload Identity, you don't need to provide `SERVICE_ACCOUNT` JSON. The pods will automatically authenticate.

---

## Authentication (WorkOS)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `WORKOS_API_KEY` | front | ✅ | WorkOS API Key |
| `WORKOS_CLIENT_ID` | front | ✅ | WorkOS Client ID |
| `WORKOS_COOKIE_PASSWORD` | front | ✅ | 32-char secret for cookie encryption |
| `WORKOS_ISSUER_URL` | front | ✅ | WorkOS issuer URL |
| `WORKOS_WEBHOOK_SECRET` | front | ✅ | Webhook verification secret |
| `WORKOS_WEBHOOK_SIGNING_SECRET` | front | ✅ | Webhook signing secret |
| `WORKOS_ACTION_SECRET` | front | ✅ | Action secret |
| `WORKOS_ACTION_SIGNING_SECRET` | front | ✅ | Action signing secret |
| `WORKOS_SESSION_COOKIE_DOMAIN` | front | ✅ | Cookie domain (your domain) |
| `WORKOS_ENVIRONMENT_ID` | front | ✅ | WorkOS environment ID |

**Where to get**:
1. Go to [WorkOS Dashboard](https://dashboard.workos.com)
2. Create an application
3. Copy API Key and Client ID from Settings
4. Configure webhooks and get secrets

**Example**:
```
WORKOS_API_KEY=
WORKOS_CLIENT_ID=client_xxxxxxxxxxxxxxxxxxxxxxxx
WORKOS_COOKIE_PASSWORD=32-character-secure-random-string!
WORKOS_ISSUER_URL=https://api.workos.com/sso/authorize
WORKOS_SESSION_COOKIE_DOMAIN=.yourdomain.com
WORKOS_ENVIRONMENT_ID=environment_xxxxxxxx
```

**How to generate WORKOS_COOKIE_PASSWORD**:
```bash
openssl rand -base64 24 | tr -d '\n' | cut -c1-32
```

---

## OAuth Provider Credentials

These are for the connectors you need (Slack, Notion, Google Drive).

### Slack

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `OAUTH_SLACK_CLIENT_ID` | front, connectors | ✅ | Slack OAuth App Client ID |
| `OAUTH_SLACK_BOT_CLIENT_ID` | connectors | ✅ | Slack Bot OAuth Client ID |
| `OAUTH_SLACK_TOOLS_CLIENT_ID` | connectors | ✅ | Slack Tools Client ID |

**Where to get**:
1. Go to [Slack API Apps](https://api.slack.com/apps)
2. Create a new app (or use existing)
3. Navigate to "OAuth & Permissions"
4. Copy the Client ID
5. Add redirect URL: `https://YOUR_DOMAIN/oauth/slack/callback`

### Notion

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `OAUTH_NOTION_CLIENT_ID` | front, connectors | ✅ | Notion Integration Client ID |
| `OAUTH_NOTION_PLATFORM_ACTIONS_CLIENT_ID` | connectors | ❌ | Platform actions client |

**Where to get**:
1. Go to [Notion Integrations](https://www.notion.so/my-integrations)
2. Create a new integration (public)
3. Copy the OAuth Client ID
4. Add redirect URL: `https://YOUR_DOMAIN/oauth/notion/callback`

### Google Drive

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `OAUTH_GOOGLE_DRIVE_CLIENT_ID` | front, connectors | ✅ | Google OAuth Client ID |

**Where to get**:
1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Navigate to "APIs & Services" > "Credentials"
3. Create OAuth 2.0 Client ID (Web application)
4. Add authorized redirect URI: `https://YOUR_DOMAIN/oauth/google/callback`
5. Enable Google Drive API

---

## External APIs

### Email (SendGrid)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `SENDGRID_API_KEY` | front | ✅ | SendGrid API key for emails |
| `SENDGRID_INVITATION_EMAIL_TEMPLATE_ID` | front | ✅ | Template ID for invitations |
| `SENDGRID_GENERIC_EMAIL_TEMPLATE_ID` | front | ✅ | Template ID for generic emails |

**Where to get**: [SendGrid Dashboard](https://app.sendgrid.com) > Settings > API Keys

### Payments (Stripe)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `STRIPE_SECRET_KEY` | front | ❌ | Stripe secret key (if using billing) |
| `STRIPE_SECRET_WEBHOOK_KEY` | front | ❌ | Stripe webhook secret |

**Where to get**: [Stripe Dashboard](https://dashboard.stripe.com) > Developers > API Keys

### File Conversion (ConvertAPI)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `CONVERTAPI_API_KEY` | front | ❌ | ConvertAPI key for file conversions |

**Where to get**: [ConvertAPI](https://www.convertapi.com/) > Account > API Secret

### Notifications (Novu)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `NOVU_SECRET_KEY` | front | ✅ | Novu API secret key |
| `NEXT_PUBLIC_NOVU_APPLICATION_IDENTIFIER` | front | ✅ | Novu app identifier |
| `NEXT_PUBLIC_NOVU_API_URL` | front | ✅ | Novu API URL |
| `NEXT_PUBLIC_NOVU_WEBSOCKET_API_URL` | front | ✅ | Novu WebSocket URL |

**Where to get**: [Novu Dashboard](https://web.novu.co) > Settings

### IP Geolocation (IPInfo)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `IPINFO_API_TOKEN` | front | ❌ | IPInfo API token |

**Where to get**: [IPInfo](https://ipinfo.io/) > Dashboard

### Status Page

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `STATUS_PAGE_PROVIDERS_PAGE_ID` | front | ❌ | Statuspage.io page ID |
| `STATUS_PAGE_DUST_PAGE_ID` | front | ❌ | Dust status page ID |
| `STATUS_PAGE_API_TOKEN` | front | ❌ | Statuspage API token |

---

## Application Configuration

### URLs & Routing

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `NEXT_PUBLIC_DUST_CLIENT_FACING_URL` | front | ✅ | Public URL of the Dust app |
| `NEXT_PUBLIC_VIZ_URL` | front | ✅ | Visualization service URL |
| `DUST_WEBHOOKS_PUBLIC_URL` | front | ❌ | Public webhooks URL |
| `DUST_REGION` | all | ✅ | Deployment region identifier |
| `DUST_EU_URL` | front | ❌ | EU region URL (multi-region) |
| `DUST_US_URL` | front | ❌ | US region URL (multi-region) |

**Example**:
```
NEXT_PUBLIC_DUST_CLIENT_FACING_URL=https://dust.yourdomain.com
NEXT_PUBLIC_VIZ_URL=https://viz.yourdomain.com
DUST_REGION=europe-west1
```

### Internal Service URLs

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `CORE_API` | front | ✅ | Core API internal URL |
| `CORE_API_KEY` | front | ❌ | Core API authentication key |
| `CONNECTORS_API` | front | ✅ | Connectors API internal URL |
| `DUST_CONNECTORS_SECRET` | front, connectors | ✅ | Shared secret for connectors |
| `OAUTH_API` | front | ✅ | OAuth service internal URL |
| `OAUTH_API_KEY` | front | ❌ | OAuth API key |
| `VIZ_JWT_SECRET` | front, viz | ✅ | JWT secret for viz auth |

**Example** (Internal GKE):
```
CORE_API=http://core.dust-app.svc.cluster.local:3001
CONNECTORS_API=http://connectors.dust-app.svc.cluster.local:3002
OAUTH_API=http://oauth.dust-app.svc.cluster.local:3006
```

### Secrets & Security

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `DUST_INVITE_TOKEN_SECRET` | front | ✅ | Secret for invitation tokens |
| `DUST_REGISTRY_SECRET` | front | ✅ | Registry secret |
| `REGION_RESOLVER_SECRET` | front | ❌ | Multi-region resolver secret |

**How to generate**:
```bash
openssl rand -hex 32
```

### Dust Apps Configuration

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `DUST_APPS_WORKSPACE_ID` | front | ✅ | Workspace ID for built-in apps |
| `DUST_APPS_SPACE_ID` | front | ✅ | Space ID for built-in apps |
| `DUST_APPS_HELPER_DATASOURCE_VIEW_ID` | front | ✅ | Helper datasource view |
| `DUST_APPS_INTERACTIVE_CONTENT_DATASOURCE_VIEW_ID` | front | ❌ | Interactive content view |
| `DUST_DEVELOPMENT_SYSTEM_API_KEY` | front | ❌ | Development API key |
| `DUST_DEVELOPMENT_WORKSPACE_ID` | front | ❌ | Development workspace |

---

## Monitoring & Observability

### Datadog (Optional)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `DATADOG_API_KEY` | all | ❌ | Datadog API key |
| `NEXT_PUBLIC_DATADOG_CLIENT_TOKEN` | front | ❌ | Datadog RUM client token |
| `NEXT_PUBLIC_DATADOG_SERVICE` | front | ❌ | Service name in Datadog |

### Langfuse (Optional)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `LANGFUSE_PUBLIC_KEY` | front | ❌ | Langfuse public key |
| `LANGFUSE_SECRET_KEY` | front | ❌ | Langfuse secret key |
| `LANGFUSE_BASE_URL` | front | ❌ | Langfuse API URL |

### PostHog (Optional)

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `NEXT_PUBLIC_POSTHOG_KEY` | front | ❌ | PostHog project key |

### Google Analytics

| Variable | Service | Required | Description |
|----------|---------|----------|-------------|
| `NEXT_PUBLIC_GTM_TRACKING_ID` | front | ❌ | Google Tag Manager ID |

---

## Environment Variables by Service

### Quick Reference: Required per Service

#### core
```bash
CORE_DATABASE_URI=
CORE_API_KEY=
ELASTICSEARCH_URL=
ELASTICSEARCH_USERNAME=
ELASTICSEARCH_PASSWORD=
QDRANT_CLUSTER_0_URL=
GCP_PROJECT_ID=
DUST_REGION=
```

#### oauth
```bash
OAUTH_DATABASE_URI=
```

#### front
```bash
NODE_ENV=production
FRONT_DATABASE_URI=
REDIS_URI=
REDIS_CACHE_URI=
CORE_API=
CONNECTORS_API=
OAUTH_API=
ELASTICSEARCH_URL=
ELASTICSEARCH_USERNAME=
ELASTICSEARCH_PASSWORD=
TEXT_EXTRACTION_URL=
WORKOS_API_KEY=
WORKOS_CLIENT_ID=
WORKOS_COOKIE_PASSWORD=
WORKOS_ISSUER_URL=
WORKOS_SESSION_COOKIE_DOMAIN=
WORKOS_ENVIRONMENT_ID=
NEXT_PUBLIC_DUST_CLIENT_FACING_URL=
NEXT_PUBLIC_VIZ_URL=
DUST_REGION=
GCP_PROJECT_ID=
DUST_UPLOAD_BUCKET=
DUST_PRIVATE_UPLOADS_BUCKET=
DUST_DATA_SOURCES_BUCKET=
DUST_INVITE_TOKEN_SECRET=
DUST_REGISTRY_SECRET=
DUST_CONNECTORS_SECRET=
VIZ_JWT_SECRET=
SENDGRID_API_KEY=
NOVU_SECRET_KEY=
```

#### front-workers
```bash
NODE_ENV=production
FRONT_DATABASE_URI=
REDIS_URI=
TEMPORAL_NAMESPACE=
TEMPORAL_AGENT_NAMESPACE=
CORE_API=
CONNECTORS_API=
GCP_PROJECT_ID=
DUST_UPSERT_QUEUE_BUCKET=
```

#### connectors
```bash
NODE_ENV=production
CONNECTORS_DATABASE_URI=
REDIS_URI=
CORE_API=
TEMPORAL_NAMESPACE=
TEMPORAL_CONNECTORS_NAMESPACE=
TEXT_EXTRACTION_URL=
DUST_CONNECTORS_SECRET=
OAUTH_SLACK_CLIENT_ID=
OAUTH_NOTION_CLIENT_ID=
OAUTH_GOOGLE_DRIVE_CLIENT_ID=
DUST_CONNECTORS_WEBHOOKS_SECRET=
```

#### viz
```bash
NODE_ENV=production
VIZ_JWT_SECRET=
```

## Additional
connectors-DUST_CONNECTORS_WEBHOOKS_SECRET
MICROSOFT_BOT_ID_SECRET	
NOTION_SIGNING_SECRET
SLACK_SIGNING_SECRET
---

## Secret Manager Setup

Store all sensitive values in GCP Secret Manager:

```bash
# Example: Creating secrets
gcloud secrets create dust-front-database-uri --replication-policy="automatic"
echo -n "postgresql://..." | gcloud secrets versions add dust-front-database-uri --data-file=-

# List all secrets to create:
# - dust-front-database-uri
# - dust-connectors-database-uri
# - dust-core-database-uri
# - dust-oauth-database-uri
# - dust-elasticsearch-password
# - dust-workos-api-key
# - dust-workos-client-id
# - dust-workos-cookie-password
# - dust-sendgrid-api-key
# - dust-novu-secret-key
# - dust-invite-token-secret
# - dust-registry-secret
# - dust-connectors-secret
# - dust-viz-jwt-secret
# - dust-oauth-slack-client-id
# - dust-oauth-notion-client-id
# - dust-oauth-google-drive-client-id
```

---

## Generating Secure Secrets

```bash
# 32-character alphanumeric
openssl rand -base64 24 | tr -d '\n' | cut -c1-32

# 64-character hex
openssl rand -hex 32

# UUID
uuidgen

# Base64 encoded JSON (for service accounts)
cat service-account.json | base64 -w 0
```

---

## Checklist

Before deploying, ensure you have:

- [ ] Created GCP Project
- [ ] Created Cloud SQL instance with all databases
- [ ] Created Memorystore Redis instance
- [ ] Created all GCS buckets
- [ ] Set up Elastic Cloud deployment
- [ ] Created WorkOS application
- [ ] Created Slack app with OAuth
- [ ] Created Notion integration
- [ ] Created Google OAuth credentials
- [ ] Created SendGrid account
- [ ] Created Novu account
- [ ] Generated all random secrets
- [ ] Stored all secrets in Secret Manager
