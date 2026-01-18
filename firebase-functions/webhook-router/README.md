# Unified Webhook Router

A secure Firebase Function that routes webhooks from Slack, Microsoft Teams, and Notion to regional endpoints with platform-specific verification.

## Features

- ✅ **Multi-platform support** - Handles Slack, Microsoft Teams, and Notion webhooks
- ✅ **Platform-specific verification** - Slack HMAC signatures + Teams JWT validation
- ✅ **Webhook secret validation** - Double security layer for both platforms
- ✅ **Single-region forwarding** - Routes to EU endpoint only
- ✅ **URL verification** - Handles Slack's URL verification challenges
- ✅ **Form-data preservation** - Maintains original webhook formats
- ✅ **Serverless scaling** - Auto-scales from 0 to N instances
- ✅ **TLS 1.2+ support** - Built-in secure connections
- ✅ **Custom domain** mapping with automatic SSL certificates

## Setup

### Prerequisites

1. Add Firebase to GCP

2. **Install Firebase CLI** (if not already installed):

   ```bash
   npm install -g firebase-tools
   ```

3. **Login to Firebase**:

   ```bash
   firebase login
   ```

4. **GCP Project Setup**:
   Your Firebase project must exist and have the required resources:

   ```bash
   # Set your GCP project ID
   export GCP_PROJECT_ID="your-gcp-project-id"
   
   # Enable required APIs
   gcloud services enable cloudfunctions.googleapis.com
   gcloud services enable secretmanager.googleapis.com
   gcloud services enable firestore.googleapis.com
   
   # Select the Firebase project
   firebase use $GCP_PROJECT_ID
   ```

5. **Create Required Secrets**:
   Create secrets in GCP Secret Manager (one-time setup):

   ```bash
   # Webhook secret - used for both webhook auth and forwarding
   gcloud secrets create connectors-DUST_CONNECTORS_WEBHOOKS_SECRET --replication-policy="automatic"
   echo -n "your-webhook-secret" | gcloud secrets versions add connectors-DUST_CONNECTORS_WEBHOOKS_SECRET --data-file=-
   
   # Platform-specific secrets
   gcloud secrets create SLACK_SIGNING_SECRET --replication-policy="automatic"
   gcloud secrets create MICROSOFT_BOT_ID_SECRET --replication-policy="automatic"
   gcloud secrets create NOTION_SIGNING_SECRET --replication-policy="automatic"
   
   # Add secret values (replace placeholders with actual values)
   echo -n "your-slack-signing-secret" | gcloud secrets versions add SLACK_SIGNING_SECRET --data-file=-
   echo -n "your-microsoft-bot-id" | gcloud secrets versions add MICROSOFT_BOT_ID_SECRET --data-file=-
   echo -n "your-notion-signing-secret" | gcloud secrets versions add NOTION_SIGNING_SECRET --data-file=-
   ```

6. **Configure IAM Permissions**:
   The webhook-router service account needs access to secrets:

   ```bash
   # Get the service account email (created by Firebase automatically)
   SERVICE_ACCOUNT=$(gcloud functions describe webhookRouter --format="value(serviceConfig.serviceAccountEmail)")
   
   # Grant secret manager accessor role
   gcloud projects get-iam-policy $GCP_PROJECT_ID \
     --flatten="bindings[].members" \
     --filter="bindings.role:roles/secretmanager.secretAccessor" \
     --format="value(bindings.members)" | while read member; do
       gcloud secrets add-iam-policy-binding connectors-DUST_CONNECTORS_WEBHOOKS_SECRET \
         --member="$member" \
         --role="roles/secretmanager.secretAccessor"
       gcloud secrets add-iam-policy-binding SLACK_SIGNING_SECRET \
         --member="$member" \
         --role="roles/secretmanager.secretAccessor"
       gcloud secrets add-iam-policy-binding MICROSOFT_BOT_ID_SECRET \
         --member="$member" \
         --role="roles/secretmanager.secretAccessor"
       gcloud secrets add-iam-policy-binding NOTION_SIGNING_SECRET \
         --member="$member" \
         --role="roles/secretmanager.secretAccessor"
     done
   ```

7. **Environment Variables**:
   Set the required GCP project IDs for deployment:
   ```bash
   export GCP_GLOBAL_PROJECT_ID="your-gcp-project-id"
   export GCP_EU_PROJECT_ID="your-gcp-project-id"
   ```

### Project Configuration

The project is configured to deploy to `dust-infra` (see `.firebaserc`). Update the project ID in `.firebaserc` if different.

## Deployment

### Deploy to Production

```bash
npm run deploy   # Builds and deploys to Firebase Functions + Hosting
```

The deploy script will:

1. Validate required environment variables
2. Create `.env` file for Firebase deployment
3. Build TypeScript
4. Deploy both function and hosting configuration

### Test Locally with Firebase Emulator

```bash
npm run dev      # Start Firebase emulator
```

## Function URLs

### Local Development (Emulator)

```
http://localhost:5001/dust-infra/us-central1/webhookRouter/YOUR_WEBHOOK_SECRET/slack/events
http://localhost:5001/dust-infra/us-central1/webhookRouter/YOUR_WEBHOOK_SECRET/slack/interactions
http://localhost:5001/dust-infra/us-central1/webhookRouter/YOUR_WEBHOOK_SECRET/microsoft/teams/messages
http://localhost:5001/dust-infra/us-central1/webhookRouter/YOUR_WEBHOOK_SECRET/notion
```

### Production

**Direct Function URL:**

```
https://us-central1-dust-infra.cloudfunctions.net/webhookRouter/YOUR_WEBHOOK_SECRET/slack/events
https://us-central1-dust-infra.cloudfunctions.net/webhookRouter/YOUR_WEBHOOK_SECRET/slack/interactions
https://us-central1-dust-infra.cloudfunctions.net/webhookRouter/YOUR_WEBHOOK_SECRET/microsoft/teams/messages
https://us-central1-dust-infra.cloudfunctions.net/webhookRouter/YOUR_WEBHOOK_SECRET/notion
```

**Custom Domain (via Firebase Hosting):**

```
https://webhook-router.dust.tt/YOUR_WEBHOOK_SECRET/slack/events
https://webhook-router.dust.tt/YOUR_WEBHOOK_SECRET/slack/interactions
https://webhook-router.dust.tt/YOUR_WEBHOOK_SECRET/microsoft/teams/messages
https://webhook-router.dust.tt/YOUR_WEBHOOK_SECRET/notion
```

## Architecture

```
Slack/Teams → Firebase Hosting → Firebase Function → [EU Endpoint]
```

**Security Flow:**

1. Validates webhook secret from URL parameter
2. Platform-specific verification:
   - **Slack**: HMAC signature validation
   - **Teams**: Bot Framework JWT token validation
3. Handles platform-specific challenges (Slack URL verification)
4. Forwards to regional endpoints asynchronously

**Body Handling:**

- **Events** (JSON): Parsed for route handlers, forwarded as JSON
- **Interactions** (form-encoded): Preserved as original format with `payload` field

## Secret Management

Uses GCP Secret Manager for production:

- `connectors-DUST_CONNECTORS_WEBHOOKS_SECRET` - Webhook secret
- `SLACK_SIGNING_SECRET` - Slack app signing secret
- `MICROSOFT_BOT_ID_SECRET` - Microsoft Bot Framework App ID

For local development, set environment variables:

```bash
export DUST_CONNECTORS_WEBHOOKS_SECRET="your-webhook-secret"
export SLACK_SIGNING_SECRET="your-slack-signing-secret"
export MICROSOFT_BOT_ID_SECRET="your-bot-app-id"
export NOTION_SIGNING_SECRET="your-notion-signing-secret"
```

## Benefits over Cloud Run

✅ **TLS 1.2+** support out of the box
✅ **Custom domain** mapping with automatic SSL certificates
✅ **No cold starts** for HTTP functions
✅ **Simpler deployment** - no container management
✅ **Built-in monitoring** and logging

## API Endpoints

### Slack Endpoints

- `POST /:webhookSecret/slack/events` - Slack events
- `POST /:webhookSecret/slack/interactions` - Slack interactions

### Microsoft Teams Endpoints

- `POST /:webhookSecret/microsoft/teams/messages` - Teams messages

### Notion Endpoint

- `POST /:webhookSecret/notion` - Notion events

## Development

```bash
npm install     # Install dependencies
npm run build   # Build TypeScript
npm run lint    # Run linter
npm run dev     # Start Firebase emulator
```

## Complete Deployment Checklist

Use this checklist for a fresh deployment:

### Step 1: GCP Prerequisites
- [ ] Create GCP project or use existing one
- [ ] Enable billing on the project
- [ ] Install and configure gcloud CLI
- [ ] Run `firebase login` and `firebase use <project-id>`

### Step 2: Enable APIs
```bash
gcloud services enable cloudfunctions.googleapis.com
gcloud services enable secretmanager.googleapis.com
gcloud services enable firestore.googleapis.com
```

### Step 3: Create Secrets
- [ ] `connectors-DUST_CONNECTORS_WEBHOOKS_SECRET` - Main webhook secret
- [ ] `SLACK_SIGNING_SECRET` - From Slack app settings
- [ ] `MICROSOFT_BOT_ID_SECRET` - From Azure portal
- [ ] `NOTION_SIGNING_SECRET` - From Notion integration settings

### Step 4: Configure Platform Webhooks
Configure the webhook URLs in each platform's developer console:

- **Slack**: `https://us-central1-<project>.cloudfunctions.net/webhookRouter/<secret>/slack/events`
- **Microsoft Teams**: `https://us-central1-<project>.cloudfunctions.net/webhookRouter/<secret>/microsoft/teams/messages`
- **Notion**: `https://us-central1-<project>.cloudfunctions.net/webhookRouter/<secret>/notion`

### Step 5: Deploy
```bash
export GCP_GLOBAL_PROJECT_ID="your-project-id"
export GCP_EU_PROJECT_ID="your-project-id"
cd firebase-functions/webhook-router
./deploy.sh
```

### Step 6: Verify
- [ ] Function deployed successfully (check Firebase Console)
- [ ] Test webhook endpoints with platform tools
- [ ] Check Cloud Logs for incoming requests
- [ ] Verify webhooks are reaching your EU connector endpoint
