#!/bin/bash

set -e

GCP_EU_PROJECT_ID=ghs-cloud-ia
GCP_GLOBAL_PROJECT_ID=ghs-cloud-ia

# Check required environment variables.
if [[ -z "$GCP_EU_PROJECT_ID" || -z "$GCP_GLOBAL_PROJECT_ID" ]]; then
  echo "❌ Error: Missing required environment variables"
  echo "   Please set: GCP_EU_PROJECT_ID and GCP_GLOBAL_PROJECT_ID"
  exit 1
fi

echo "🔧 Project Configuration:"
echo "  Global Project: $GCP_GLOBAL_PROJECT_ID (webhook secrets)"
echo "  EU Project: $GCP_EU_PROJECT_ID (connector secrets)"

echo "🔧 Creating .env file for Firebase deployment..."
cat > .env << EOF
GCP_GLOBAL_PROJECT_ID=$GCP_GLOBAL_PROJECT_ID
GCP_EU_PROJECT_ID=$GCP_EU_PROJECT_ID
SERVICE_ACCOUNT=webhook-router-sa@$GCP_GLOBAL_PROJECT_ID.iam.gserviceaccount.com
EOF

echo "🏗️ Building TypeScript..."
npm run build

echo "🚀 Deploying webhook-router to Firebase Functions..."

# Deploy to Firebase Functions and Hosting
firebase deploy --only functions

echo "✅ Deployment complete!"
echo "🌍 Function available at: https://us-central1-dust-infra.cloudfunctions.net/webhookRouter"
