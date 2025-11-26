# [Dust](https://dust.tt)

## 🚀 Local Dust Full-Stack Setup – Complete README

This document summarizes **all steps required** to run the Dust platform locally using:

- Docker (infra: Postgres, Redis, Qdrant cluster, Tika, Elasticsearch, Kibana)
- Frontend (Next.js)
- Backend (Rust / Axum-based Dust Core)
- Correct environment variables
- Correct wiring between all components

This README captures **every fix, discovery and configuration** used to get the system  working.

---

## 🐳 1. Start Infrastructure with Docker

The provided `docker-compose.yml` launches all **non-Dust services**:

```bash
docker compose up -d
```

This starts:

| Service | Purpose | Port |
|---------|---------|------|
| Postgres | main database | 5432 |
| Redis | caching + workers | 6379 |
| Qdrant primary | vector DB | 6333 |
| Qdrant secondary | clustering replica | 6334 |
| Apache Tika | file/text extraction | 9998 |
| Elasticsearch | search engine | 9200 |
| Kibana | ES UI | 5601 |

**Important:**  
Docker *does not* start the Dust backend. Only infra.

---

## 🔧 2. Install Node Version Manager (nvm)

Dust frontend requires a specific Node version.  
Install NVM:

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
```

Add to `~/.zshrc`:

```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
```

Reload:

```bash
source ~/.zshrc
```

Install the version specified in `front/.nvmrc`:

```bash
cd front
nvm install
nvm use
```

---

## 📦 3. Fix Frontend SDK Dependency

The frontend originally expected a local SDK via:

```json
"@dust-tt/client": "file:../sdks/js"
```

But since you're running outside the dev workspace, replace it with:

```json
"@dust-tt/client": "latest"
```

or 

```json
"@dust-tt/client": "^1.1.18"
```

Then reinstall:

```bash
rm -rf node_modules package-lock.json
npm install
```

---

## 🌐 4. Frontend .env Setup

The frontend does NOT use `.env.local`.  
It requires `.env` in `front/`.

Create:

```
front/.env
```

Minimal working version:

```env
DUST_REGION=local

NEXT_PUBLIC_BACKEND_URL=http://localhost:3002
BACKEND_URL=http://localhost:3002

NEXT_PUBLIC_FRONTEND_URL=http://localhost:3001
FRONTEND_URL=http://localhost:3001

FRONT_DATABASE_URI=postgresql://dev:dev@localhost:5432/dev

NEXT_PUBLIC_QDRANT_URL=http://localhost:6333
NEXT_PUBLIC_ELASTICSEARCH_URL=http://localhost:9200
```

Start frontend:

```bash
cd front
npm run dev
```

---

## 🦀 6. Rust Backend – Important Notes

The backend in `core/` is written in **Rust**, not Node.  
It **does not automatically load `.env`** (unless you add `dotenvy::dotenv()` manually).

This means:

- You must run the backend **from inside the core directory**
- Env vars must be provided via `.env` in `core/` (picked up by shell)  
  or exported into the environment manually

---

## 🛠 7. Backend Required Environment Variables

From inspection of `core/src/bin/core_api.rs` and related modules, the backend requires:

### **Core**
```
CORE_DATABASE_URI
REDIS_URI
DUST_API_KEY
```

### **Qdrant Cluster**
```
QDRANT_CLUSTER_0_URL
QDRANT_CLUSTER_0_API_KEY
QDRANT_CLUSTER_1_URL
QDRANT_CLUSTER_1_API_KEY
```

### **Elasticsearch**
```
ELASTICSEARCH_URL
ELASTICSEARCH_USERNAME
ELASTICSEARCH_PASSWORD
```

### **File/Text Extraction**
```
TIKA_URL
```

### **Google Storage (dummy for local)**
```
GOOGLE_APPLICATION_CREDENTIALS
```

---

## 📁 8. Backend .env Configuration

Create:

```
core/.env
```

Contents:

```env
# Database
CORE_DATABASE_URI=postgresql://dev:dev@localhost:5432/dev

# Redis
REDIS_URI=redis://localhost:6379

# Elasticsearch
ELASTICSEARCH_URL=http://localhost:9200
ELASTICSEARCH_USERNAME=elastic
ELASTICSEARCH_PASSWORD=changeme

# Qdrant (anonymous access)
QDRANT_CLUSTER_0_URL=http://localhost:6333
QDRANT_CLUSTER_0_API_KEY=
QDRANT_CLUSTER_1_URL=http://localhost:6334
QDRANT_CLUSTER_1_API_KEY=

# Tika
TIKA_URL=http://localhost:9998

# GCS placeholder
GOOGLE_APPLICATION_CREDENTIALS=dummy.json

# Local API key
DUST_API_KEY=dev-key
```

---

## 🚀 9. Run the Rust Backend

The backend offers multiple binaries. The **main server** is:

```
core-api
```

Run:

```bash
cd core
cargo run --bin core-api
```

Expected output:

```
dust_api server started
Connected to Postgres
Connected to Redis
Connected to Qdrant
Connected to Elasticsearch
```

If an env variable is missing, it will panic and tell you which one.

---

## 🧩 10. Fixes Applied During Setup

### **Frontend Issues Fixed**
- Installed nvm + correct Node version
- Removed invalid `file:../sdks/js` dependency
- Switched to actual NPM package `@dust-tt/client`
- Created correct `front/.env`
- Fixed missing required variables
- Resolved module resolution errors

### **Backend Issues Fixed**
- Identified correct Rust binary: `core-api`
- Ensured running from the correct directory (`core/`)
- Discovered Rust didn't load `.env` → rely on shell + local `.env`
- Added missing required vars:
  - `CORE_DATABASE_URI`
  - `REDIS_URI`
  - `ELASTICSEARCH_*`
  - `QDRANT_CLUSTER_*`
  - `TIKA_URL`
- Fixed Qdrant cluster auth by setting empty API keys

### **Infrastructure Issues Fixed**
- Confirmed Docker runs only infra, not backend
- Matched ports correctly
- Ensured cluster environment variables for Qdrant
- Connected frontend ↔ backend ↔ DB ↔ Qdrant ↔ Redis ↔ ES

---

## 🎉 11. Full Startup Procedure

## 1. Start infrastructure:

```bash
docker compose up -d
```

## 2. Start backend:

```bash
cd core
cargo run --bin core-api
```

## 3. Start frontend:

```bash
cd front
npm run dev
```

---

## Left to do to get fully working

