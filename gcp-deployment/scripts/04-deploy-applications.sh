#!/bin/bash
# =============================================================================
# Dust Application Deployment Script
# =============================================================================
# This script builds and deploys all Dust application services to GKE.
# Run this AFTER 03-deploy-temporal.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
PROJECT_ID="ghs-cloud-ia"
REGION="${REGION:-europe-west4}"
GKE_CLUSTER_NAME="dust-cluster"
NAMESPACE="dust-app"
REPOSITORY="dust-images"

# Image tag (use 'latest' or specific commit SHA)
IMAGE_TAG="${IMAGE_TAG:-latest}"

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
log_info "Starting application deployment..."

gcloud config set project "${PROJECT_ID}"
gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" --region="${REGION}"

# Check if namespace exists
kubectl get namespace "${NAMESPACE}" &>/dev/null || kubectl create namespace "${NAMESPACE}"

# =============================================================================
# BUILD IMAGES (Optional - can skip if images already built via CI)
# =============================================================================
read -p "Build images now? (y/N): " BUILD_IMAGES
BUILD_IMAGES=${BUILD_IMAGES:-n}

if [[ "${BUILD_IMAGES}" =~ ^[Yy]$ ]]; then
    log_info "Triggering Cloud Build for all services..."
    
    # Get the repository root
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
    
    # log_info "Building Core..."
    # gcloud builds submit "${REPO_ROOT}" \
    #     --config="${REPO_ROOT}/gcp-deployment/cloudbuild/cloudbuild-core.yaml" \
    #     --async
    
    log_info "Building Front..."
    gcloud builds submit "${REPO_ROOT}" \
        --config="${REPO_ROOT}/gcp-deployment/cloudbuild/cloudbuild-front.yaml" \
        --async
    
    # log_info "Building Connectors..."
    # gcloud builds submit "${REPO_ROOT}" \
    #     --config="${REPO_ROOT}/gcp-deployment/cloudbuild/cloudbuild-connectors.yaml" \
    #     --async
    
    # log_info "Building Viz..."
    # gcloud builds submit "${REPO_ROOT}" \
    #     --config="${REPO_ROOT}/gcp-deployment/cloudbuild/cloudbuild-viz.yaml" \
    #     --async
    
    log_info "Builds submitted. Check Cloud Build console for progress."
    log_info "Re-run this script after builds complete."
    exit 0
fi

# =============================================================================
# DEPLOY QDRANT (Vector Database)
# =============================================================================
log_info "Deploying Qdrant..."

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: qdrant
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: qdrant
  namespace: qdrant
spec:
  serviceName: qdrant
  replicas: 1
  selector:
    matchLabels:
      app: qdrant
  template:
    metadata:
      labels:
        app: qdrant
    spec:
      containers:
        - name: qdrant
          image: qdrant/qdrant:v1.13.0
          ports:
            - containerPort: 6333
            - containerPort: 6334
          volumeMounts:
            - name: qdrant-storage
              mountPath: /qdrant/storage
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: 500m
              memory: 1Gi
  volumeClaimTemplates:
    - metadata:
        name: qdrant-storage
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: premium-rwo
        resources:
          requests:
            storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: qdrant
  namespace: qdrant
spec:
  selector:
    app: qdrant
  ports:
    - name: http
      port: 6333
      targetPort: 6333
    - name: grpc
      port: 6334
      targetPort: 6334
EOF

# =============================================================================
# DEPLOY APACHE TIKA
# =============================================================================
log_info "Deploying Apache Tika..."

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: tika
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tika
  namespace: tika
spec:
  replicas: 2
  selector:
    matchLabels:
      app: tika
  template:
    metadata:
      labels:
        app: tika
    spec:
      containers:
        - name: tika
          image: apache/tika:2.9.2.1-full
          ports:
            - containerPort: 9998
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi
          readinessProbe:
            httpGet:
              path: /tika
              port: 9998
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /tika
              port: 9998
            initialDelaySeconds: 60
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: tika
  namespace: tika
spec:
  selector:
    app: tika
  ports:
    - port: 9998
      targetPort: 9998
EOF

# =============================================================================
# CREATE CONFIGMAP WITH ENVIRONMENT CONFIGURATION
# =============================================================================
log_info "Creating ConfigMap with environment configuration..."

# Get infrastructure values
CLOUDSQL_IP=$(gcloud sql instances describe dust-postgres --format="value(ipAddresses[0].ipAddress)" 2>/dev/null || echo "CLOUDSQL_IP_NOT_SET")
REDIS_IP=$(gcloud redis instances describe dust-redis --region="${REGION}" --format="value(host)" 2>/dev/null || echo "REDIS_IP_NOT_SET")

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: dust-config
  namespace: ${NAMESPACE}
data:
  NODE_ENV: "production"
  DUST_REGION: "${REGION}"
  
  # Internal Service URLs
  CORE_API: "http://core.${NAMESPACE}.svc.cluster.local:3001"
  CONNECTORS_API: "http://connectors-web.${NAMESPACE}.svc.cluster.local:3002"
  OAUTH_API: "http://oauth.${NAMESPACE}.svc.cluster.local:3006"
  TEXT_EXTRACTION_URL: "http://tika.tika.svc.cluster.local:9998"
  
  # Temporal (Self-hosted)
  TEMPORAL_ADDRESS: "temporal-frontend.temporal.svc.cluster.local:7233"
  TEMPORAL_NAMESPACE: "dust-front"
  TEMPORAL_AGENT_NAMESPACE: "dust-agent"
  TEMPORAL_CONNECTORS_NAMESPACE: "dust-connectors"
  TEMPORAL_RELOCATION_NAMESPACE: "dust-relocation"
  
  # Qdrant
  QDRANT_CLUSTER_0_URL: "http://qdrant.qdrant.svc.cluster.local:6334"
  
  # Redis
  REDIS_URI: "redis://${REDIS_IP}:6379"
  REDIS_CACHE_URI: "redis://${REDIS_IP}:6379"
  
  # PostgreSQL Host (passwords in secrets)
  POSTGRES_HOST: "${CLOUDSQL_IP}"
EOF

# =============================================================================
# NOTE: SECRETS MUST BE CREATED MANUALLY
# =============================================================================
log_info "IMPORTANT: You need to create Kubernetes secrets manually."
log_info "See docs/SECRETS.md for the full list of required secrets."

cat <<EOF

============================================================================
MANUAL STEP REQUIRED: Create Kubernetes Secrets
============================================================================

Create the following secrets before deploying applications:

kubectl create secret generic dust-secrets -n ${NAMESPACE} \\
  --from-literal=FRONT_DATABASE_URI="postgresql://dustapp:PASSWORD@${CLOUDSQL_IP}:5432/dust_front" \\
  --from-literal=CONNECTORS_DATABASE_URI="postgresql://dustapp:PASSWORD@${CLOUDSQL_IP}:5432/dust_connectors" \\
  --from-literal=CORE_DATABASE_URI="postgresql://dustapp:PASSWORD@${CLOUDSQL_IP}:5432/dust_api" \\
  --from-literal=OAUTH_DATABASE_URI="postgresql://dustapp:PASSWORD@${CLOUDSQL_IP}:5432/dust_oauth" \\
  --from-literal=ELASTICSEARCH_URL="YOUR_ELASTIC_CLOUD_URL" \\
  --from-literal=ELASTICSEARCH_USERNAME="elastic" \\
  --from-literal=ELASTICSEARCH_PASSWORD="YOUR_ELASTIC_PASSWORD" \\
  --from-literal=WORKOS_API_KEY="YOUR_WORKOS_API_KEY" \\
  --from-literal=WORKOS_CLIENT_ID="YOUR_WORKOS_CLIENT_ID" \\
  --from-literal=WORKOS_COOKIE_PASSWORD="\$(openssl rand -base64 24 | cut -c1-32)" \\
  --from-literal=DUST_INVITE_TOKEN_SECRET="\$(openssl rand -hex 32)" \\
  --from-literal=DUST_REGISTRY_SECRET="\$(openssl rand -hex 32)" \\
  --from-literal=DUST_CONNECTORS_SECRET="\$(openssl rand -hex 32)" \\
  --from-literal=VIZ_JWT_SECRET="\$(openssl rand -hex 32)" \\
  --from-literal=SENDGRID_API_KEY="YOUR_SENDGRID_KEY" \\
  --from-literal=NOVU_SECRET_KEY="YOUR_NOVU_KEY"

Press Enter after creating secrets to continue...
EOF

read -p ""

# =============================================================================
# DEPLOY CORE SERVICE
# =============================================================================
log_info "Deploying Core service..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: core
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: core
  template:
    metadata:
      labels:
        app: core
    spec:
      serviceAccountName: dust-app-sa
      containers:
        - name: core
          image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/core:${IMAGE_TAG}
          ports:
            - containerPort: 3001
          envFrom:
            - configMapRef:
                name: dust-config
            - secretRef:
                name: dust-secrets
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi
          readinessProbe:
            httpGet:
              path: /healthz
              port: 3001
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 3001
            initialDelaySeconds: 30
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: core
  namespace: ${NAMESPACE}
spec:
  selector:
    app: core
  ports:
    - port: 3001
      targetPort: 3001
EOF

# =============================================================================
# DEPLOY OAUTH SERVICE
# =============================================================================
log_info "Deploying OAuth service..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: oauth
  template:
    metadata:
      labels:
        app: oauth
    spec:
      serviceAccountName: dust-app-sa
      containers:
        - name: oauth
          image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/oauth:${IMAGE_TAG}
          ports:
            - containerPort: 3006
          envFrom:
            - configMapRef:
                name: dust-config
            - secretRef:
                name: dust-secrets
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: oauth
  namespace: ${NAMESPACE}
spec:
  selector:
    app: oauth
  ports:
    - port: 3006
      targetPort: 3006
EOF

# =============================================================================
# DEPLOY CONNECTORS WEB & WORKER
# =============================================================================
log_info "Deploying Connectors services..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: connectors-web
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: connectors-web
  template:
    metadata:
      labels:
        app: connectors-web
    spec:
      serviceAccountName: dust-app-sa
      containers:
        - name: connectors-web
          image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/connectors:${IMAGE_TAG}
          command: ["npm", "run", "start:web"]
          ports:
            - containerPort: 3002
          envFrom:
            - configMapRef:
                name: dust-config
            - secretRef:
                name: dust-secrets
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: 500m
              memory: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: connectors-web
  namespace: ${NAMESPACE}
spec:
  selector:
    app: connectors-web
  ports:
    - port: 3002
      targetPort: 3002
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: connectors-worker
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: connectors-worker
  template:
    metadata:
      labels:
        app: connectors-worker
    spec:
      serviceAccountName: dust-app-sa
      containers:
        - name: connectors-worker
          image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/connectors:${IMAGE_TAG}
          command: ["npm", "run", "start:worker"]
          envFrom:
            - configMapRef:
                name: dust-config
            - secretRef:
                name: dust-secrets
          resources:
            requests:
              cpu: 200m
              memory: 1Gi
            limits:
              cpu: 1000m
              memory: 4Gi
EOF

# =============================================================================
# DEPLOY FRONT & FRONT-WORKERS
# =============================================================================
log_info "Deploying Front services..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: front
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: front
  template:
    metadata:
      labels:
        app: front
    spec:
      serviceAccountName: dust-app-sa
      containers:
        - name: front
          image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/front:${IMAGE_TAG}
          ports:
            - containerPort: 3000
          envFrom:
            - configMapRef:
                name: dust-config
            - secretRef:
                name: dust-secrets
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi
          readinessProbe:
            httpGet:
              path: /api/healthz
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: front
  namespace: ${NAMESPACE}
spec:
  selector:
    app: front
  ports:
    - port: 3000
      targetPort: 3000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: front-workers
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: front-workers
  template:
    metadata:
      labels:
        app: front-workers
    spec:
      serviceAccountName: dust-app-sa
      containers:
        - name: front-workers
          image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/front:${IMAGE_TAG}
          command: ["npm", "run", "start:worker"]
          envFrom:
            - configMapRef:
                name: dust-config
            - secretRef:
                name: dust-secrets
          resources:
            requests:
              cpu: 200m
              memory: 1Gi
            limits:
              cpu: 1000m
              memory: 4Gi
EOF

# =============================================================================
# DEPLOY VIZ
# =============================================================================
log_info "Deploying Viz service..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: viz
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: viz
  template:
    metadata:
      labels:
        app: viz
    spec:
      serviceAccountName: dust-app-sa
      containers:
        - name: viz
          image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/viz:${IMAGE_TAG}
          ports:
            - containerPort: 3000
          envFrom:
            - configMapRef:
                name: dust-config
            - secretRef:
                name: dust-secrets
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: viz
  namespace: ${NAMESPACE}
spec:
  selector:
    app: viz
  ports:
    - port: 3000
      targetPort: 3000
EOF

# =============================================================================
# DEPLOY ELASTICSEARCH (Self-hosted, single-node)
# =============================================================================
log_info "Deploying Elasticsearch..."

kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: elastic
---
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
  namespace: elastic
spec:
  selector:
    app: elasticsearch
  ports:
    - name: http
      port: 9200
      targetPort: 9200
  type: ClusterIP
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: elastic
spec:
  serviceName: elasticsearch
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      terminationGracePeriodSeconds: 120
      containers:
        - name: elasticsearch
          image: docker.elastic.co/elasticsearch/elasticsearch:8.13.4
          ports:
            - containerPort: 9200
              name: http
            - containerPort: 9300
              name: transport
          env:
            # Single node mode for dev/POC
            - name: discovery.type
              value: single-node

            # IMPORTANT: This disables Elasticsearch security (no auth, no TLS).
            # Good for quick internal cluster usage only.
            - name: xpack.security.enabled
              value: "false"

            # Keep memory sane on small nodes
            - name: ES_JAVA_OPTS
              value: "-Xms1g -Xmx1g"

            # Helps avoid bootstrap checks in small environments
            - name: bootstrap.memory_lock
              value: "false"
          resources:
            requests:
              cpu: 250m
              memory: 2Gi
            limits:
              cpu: "1"
              memory: 3Gi
          volumeMounts:
            - name: es-data
              mountPath: /usr/share/elasticsearch/data
          readinessProbe:
            httpGet:
              path: /
              port: 9200
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 2
          livenessProbe:
            httpGet:
              path: /
              port: 9200
            initialDelaySeconds: 60
            periodSeconds: 20
            timeoutSeconds: 2
  volumeClaimTemplates:
    - metadata:
        name: es-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: premium-rwo
        resources:
          requests:
            storage: 30Gi
EOF

# =============================================================================
# WAIT FOR DEPLOYMENTS
# =============================================================================
log_info "Waiting for deployments to be ready..."

for deploy in elastic; do
    kubectl rollout status deployment/${deploy} -n ${NAMESPACE} --timeout=300s || \
        log_warn "Deployment ${deploy} not ready yet"
done

# =============================================================================
# OUTPUT SUMMARY
# =============================================================================
echo ""
echo "============================================================================="
log_info "Application Deployment Complete!"
echo "============================================================================="
echo ""
echo "Deployed Services:"
kubectl get deployments -n ${NAMESPACE}
echo ""
echo "Services:"
kubectl get services -n ${NAMESPACE}
echo ""
echo "============================================================================="
echo "Next Steps:"
echo "  1. Run: ./05-init-databases.sh"
echo "  2. Set up Ingress/Load Balancer for external access"
echo "  3. Configure SSL certificates"
echo "============================================================================="
