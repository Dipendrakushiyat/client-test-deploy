#!/bin/bash

# Local Deploy Test Script (NO SSH)
# Usage: ./local-deploy.sh <domain> <images> <client_name>

set -e

# ------------------------
# CONFIGURATION
# ------------------------
BASE_PROJECTS_DIR="./svg-app"
DEPLOY_BASE_PATH="./svg-deploy"
BACKUP_DIR="./backups"
COMPOSE_FILE="docker-compose.yml"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# DB config (local docker)
DB_CONTAINER_NAME="postgres_db"
DB_NAME="myapp_db"
DB_USER="postgres"

# ------------------------
# LOGGING
# ------------------------
log() { echo "[INFO] $(date '+%H:%M:%S') - $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_success() { echo "[SUCCESS] $*"; }
log_step() { echo "[STEP] $*"; }

# ------------------------
# VALIDATION
# ------------------------
if [ $# -lt 3 ]; then
    log_error "Usage: $0 <domain> <images> <client_name>"
    exit 1
fi

DOMAIN="$1"
IMAGES="$2"
CLIENT_NAME="$3"

PROJECT_PATH="$DEPLOY_BASE_PATH/$CLIENT_NAME"
LOCAL_COMPOSE_PATH="./local-run"

mkdir -p "$BACKUP_DIR"
mkdir -p "$LOCAL_COMPOSE_PATH"

# ------------------------
# STEP 1: SIMULATE GIT PULL
# ------------------------
log_step "SIMULATING GIT PULL (LOCAL)"
echo "git fetch origin && git checkout dev && git reset --hard origin/dev"

# ------------------------
# STEP 2: BACKUP COMPOSE FILE
# ------------------------
log_step "BACKUP COMPOSE FILE"

if [ -f "$LOCAL_COMPOSE_PATH/$COMPOSE_FILE" ]; then
    cp "$LOCAL_COMPOSE_PATH/$COMPOSE_FILE" \
       "$BACKUP_DIR/docker-compose.$TIMESTAMP.bak"
    log_success "Compose backup created"
else
    log "No existing compose file to backup"
fi

# ------------------------
# STEP 3: COPY COMPOSE FILE
# ------------------------
log_step "COPYING NEW COMPOSE FILE"

if [ -f "$PROJECT_PATH/$COMPOSE_FILE" ]; then
    cp "$PROJECT_PATH/$COMPOSE_FILE" "$LOCAL_COMPOSE_PATH/docker-compose.yml"
    log_success "Compose copied locally"
else
    log_error "Compose file not found in project path"
    exit 1
fi

# ------------------------
# STEP 4: DATABASE BACKUP (LOCAL)
# ------------------------
log_step "DATABASE BACKUP (SIMULATED)"

if docker ps -q -f name=$DB_CONTAINER_NAME | grep -q .; then
    log "DB container found, creating dump..."

    docker exec $DB_CONTAINER_NAME \
        pg_dump -U $DB_USER $DB_NAME > \
        "$BACKUP_DIR/db_backup_$TIMESTAMP.sql"

    log_success "DB backup created"
else
    log "No DB container running - skipping backup"
fi

# ------------------------
# STEP 5: STOP CONTAINERS
# ------------------------
log_step "STOPPING LOCAL CONTAINERS"

if [ -f "$LOCAL_COMPOSE_PATH/docker-compose.yml" ]; then
    cd "$LOCAL_COMPOSE_PATH"
    docker compose down || true
    cd - > /dev/null
else
    log "No compose file found to stop"
fi

# ------------------------
# STEP 6: IMAGE CLEANUP (LOCAL ONLY)
# ------------------------
log_step "IMAGE CLEANUP"

if [ "$IMAGES" = "all" ]; then
    images=$(grep -E 'image:' "$LOCAL_COMPOSE_PATH/docker-compose.yml" 2>/dev/null | awk '{print $2}' | sort -u || true)

    for img in $images; do
        docker rmi "$img" 2>/dev/null || true
    done
else
    for img in $(echo "$IMAGES" | tr ',' ' '); do
        docker rmi "$img" 2>/dev/null || true
    done
fi

# ------------------------
# STEP 7: START CONTAINERS
# ------------------------
log_step "STARTING CONTAINERS"

cd "$LOCAL_COMPOSE_PATH"
docker compose pull || true
docker compose up -d
cd - > /dev/null

# ------------------------
# STEP 8: HEALTH CHECK
# ------------------------
log_step "HEALTH CHECK"

sleep 5

health_url="http://localhost:3000/api/health"

if curl -s -f --max-time 5 "$health_url" > /dev/null; then
    log_success "Health check passed"
else
    log_error "Health check failed"
fi

log_success "LOCAL DEPLOY SIMULATION COMPLETE"