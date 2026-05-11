#!/bin/bash

# Simple Deploy Script with Integrated Rollback
# -----------------------------------------------
# DEPLOY  Usage: ./simple-deploy.sh <domain> <images> <client_name>
# ROLLBACK Usage: ./simple-deploy.sh --rollback <domain> <client_name> [backup_timestamp]
#
# Examples:
#   Deploy:   ./simple-deploy.sh delta.solvrays.ai "web,api,worker" clientA
#   Deploy:   ./simple-deploy.sh beta.solvrays.ai "all" clientB
#   Rollback: ./simple-deploy.sh --rollback delta.solvrays.ai clientA
#   Rollback: ./simple-deploy.sh --rollback delta.solvrays.ai clientA 20260511_143000

set -euo pipefail

# ------------------------
# CONFIGURATION
# ------------------------
# Docker binary (local machine — used in SSH one-liners; remote backup/restore resolves its own).
# Override with: DEPLOY_DOCKER_BIN=/usr/bin/docker ./simple-deploy.sh ...
DOCKER_BIN="${DEPLOY_DOCKER_BIN:-}"
if [ -z "$DOCKER_BIN" ] || [ ! -x "$DOCKER_BIN" ]; then
    if [ -x "/opt/homebrew/bin/docker" ]; then
        DOCKER_BIN="/opt/homebrew/bin/docker"
    elif command -v docker >/dev/null 2>&1; then
        DOCKER_BIN="$(command -v docker)"
    else
        DOCKER_BIN="/usr/bin/docker"
    fi
fi

# Bash snippet injected on the SSH target. Resolves docker on the *remote* (no Mac path leaked to Linux).
# Prefer Compose V2 (`docker compose`), fall back to standalone `docker-compose`.
REMOTE_COMPOSE_HELPER='
_docker_bin() {
    if [ -n "${DOCKER_BIN:-}" ] && [ -x "$DOCKER_BIN" ]; then printf %s "$DOCKER_BIN"
    elif [ -x "/opt/homebrew/bin/docker" ]; then printf %s "/opt/homebrew/bin/docker"
    elif command -v docker >/dev/null 2>&1; then command -v docker
    else printf %s "/usr/bin/docker"; fi
}
# Standalone docker-compose: SSH often has a minimal PATH, so Homebrew is missed by command -v alone.
_docker_compose_v1_path() {
    local p _path dc
    _path="${PATH:-}"
    for p in /opt/homebrew/bin /usr/local/bin /usr/bin "${HOME:-}/.local/bin"; do
        case ":${_path}:" in *":${p}:"*) ;; *) _path="${_path:+${_path}:}${p}";; esac
    done
    dc="$(PATH="$_path" command -v docker-compose 2>/dev/null)" || true
    if [ -n "${dc:-}" ] && [ -x "$dc" ]; then printf %s "$dc"; return 0; fi
    for p in /opt/homebrew/bin/docker-compose /usr/local/bin/docker-compose; do
        [ -x "$p" ] || continue
        printf %s "$p"
        return 0
    done
    return 1
}
docker_compose() {
    local d dc1
    d="$(_docker_bin)"
    if [ -x "$d" ] && "$d" compose version >/dev/null 2>&1; then
        "$d" compose "$@"
        return
    fi
    if dc1="$(_docker_compose_v1_path)"; then
        "$dc1" "$@"
        return
    fi
    echo "[REMOTE-ERROR] Docker Compose unavailable. On this Mac: brew install docker-compose" >&2
    echo "[REMOTE-ERROR] or use Docker Desktop with Compose v2 so '\''docker compose'\'' works." >&2
    return 127
}
'

# Run a remote shell line after defining docker_compose (uses remote docker path).
remote_with_compose() {
    local server="$1"
    shift
    ssh_cmd "$server" "${REMOTE_COMPOSE_HELPER}
$*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BASE_PROJECTS_DIR="/projects/svg-app"
BASE_PROJECTS_DIR="$HOME/Downloads/deploy-test"
DEFAULT_BRANCH="dev"
# SSH_USER="${DEPLOY_SSH_USER:-ubuntu}"
SSH_USER="${DEPLOY_SSH_USER:-$USER}"
# SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/gcp-key}"
# SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/deploy-test-key}"
SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/deploy-test-key}"
SSH_PORT="${DEPLOY_SSH_PORT:-22}"
# COMPOSE_REMOTE_PATH="${DEPLOY_COMPOSE_PATH:-/home/ubuntu}"
COMPOSE_REMOTE_PATH="${DEPLOY_COMPOSE_PATH:-$HOME/deploy-test/remote-server}"
HEALTH_CHECK_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-120}"
HEALTH_CHECK_INTERVAL="${DEPLOY_HEALTH_INTERVAL:-5}"
BACKUPS_ROOT="$COMPOSE_REMOTE_PATH/backups"

# ------------------------
# LOGGING FUNCTIONS
# ------------------------
log() {
    echo "[INFO]    $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
    echo "[ERROR]   $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_step() {
    echo ""
    echo "=========================================================="
    echo "[STEP]    $(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo "=========================================================="
}

log_warn() {
    echo "[WARN]    $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# ------------------------
# SSH / SCP HELPERS
# ------------------------
ssh_cmd() {
    local server="$1"
    shift
    ssh -i "$SSH_KEY" -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        "$SSH_USER@$server" "$@"
}

scp_cmd() {
    local src="$1"
    local dest="$2"
    scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no "$src" "$SSH_USER@$dest"
}

# Sync project tree to the remote compose directory so `build:` contexts and bind mounts (.) work.
# Intentionally no --delete: avoids wiping remote-only paths such as backups/ under the same tree.
rsync_project_to_remote() {
    local server="$1"
    local src_dir="$2"
    local dest_dir="$3"
    if ! command -v rsync >/dev/null 2>&1; then
        log_error "rsync is not installed locally; install it or add rsync on the PATH."
        return 1
    fi
    rsync -az \
        -e "ssh -i \"$SSH_KEY\" -p \"$SSH_PORT\" -o StrictHostKeyChecking=no" \
        --exclude 'node_modules' \
        --exclude '.git' \
        --exclude '.next' \
        --exclude 'dist' \
        "${src_dir%/}/" "${SSH_USER}@${server}:${dest_dir%/}/"
}

# Run a heredoc script on the remote server, passing positional args after the script
ssh_script() {
    local server="$1"
    local script_body="$2"
    shift 2
    ssh_cmd "$server" "bash -s -- $*" <<< "$script_body"
}

# ============================================================
# REMOTE HELPER: backup_current_state
#   $1 = COMPOSE_DIR   (where docker-compose.yml lives remotely)
#   $2 = BACKUP_DIR    (target backup folder on the remote)
# ============================================================
REMOTE_BACKUP_FN="${REMOTE_COMPOSE_HELPER}"'
set -euo pipefail
COMPOSE_DIR="$1"
BACKUP_DIR="$2"
if [ -z "${DOCKER_BIN:-}" ] || [ ! -x "$DOCKER_BIN" ]; then
    if [ -x "/opt/homebrew/bin/docker" ]; then DOCKER_BIN="/opt/homebrew/bin/docker"
    elif command -v docker >/dev/null 2>&1; then DOCKER_BIN="$(command -v docker)"
    else DOCKER_BIN="/usr/bin/docker"; fi
fi

log_r()  { echo "[REMOTE-INFO]    $(date "+%Y-%m-%d %H:%M:%S") - $*"; }
log_re() { echo "[REMOTE-ERROR]   $(date "+%Y-%m-%d %H:%M:%S") - $*" >&2; }
log_rs() { echo "[REMOTE-SUCCESS] $(date "+%Y-%m-%d %H:%M:%S") - $*"; }

log_r "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" || { log_re "Cannot create backup dir"; exit 1; }

# --- Backup docker-compose.yml ---
if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    cp "$COMPOSE_DIR/docker-compose.yml" "$BACKUP_DIR/docker-compose.yml" \
        || { log_re "Failed to copy docker-compose.yml"; exit 1; }
    log_rs "docker-compose.yml backed up"
else
    log_r "No docker-compose.yml found in $COMPOSE_DIR – nothing to back up for compose"
fi

# --- Backup .env if present ---
if [ -f "$COMPOSE_DIR/.env" ]; then
    cp "$COMPOSE_DIR/.env" "$BACKUP_DIR/.env" || true
    log_r ".env file backed up"
fi

# --- Database backup ---
DB_CONTAINER=$(cd "$COMPOSE_DIR" && docker_compose ps -q postgres 2>/dev/null || true)
if [ -z "$DB_CONTAINER" ]; then
    DB_CONTAINER=$(cd "$COMPOSE_DIR" && docker_compose ps -q db 2>/dev/null || true)
fi

if [ -n "$DB_CONTAINER" ]; then
    log_r "Found running DB container: $DB_CONTAINER"

    DB_USER=$($DOCKER_BIN inspect --format="{{range .Config.Env}}{{println .}}{{end}}" "$DB_CONTAINER" \
        | grep "^POSTGRES_USER=" | cut -d= -f2 || true)
    DB_NAME=$($DOCKER_BIN inspect --format="{{range .Config.Env}}{{println .}}{{end}}" "$DB_CONTAINER" \
        | grep "^POSTGRES_DB=" | cut -d= -f2 || true)

    DB_USER="${DB_USER:-ubuntu}"
    DB_NAME="${DB_NAME:-svg_delta}"

    log_r "Dumping database: $DB_NAME (user: $DB_USER)"
    $DOCKER_BIN exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -F c -f "/tmp/db_backup.dump" \
        || { log_re "pg_dump failed"; exit 1; }
    $DOCKER_BIN cp "$DB_CONTAINER:/tmp/db_backup.dump" "$BACKUP_DIR/db_backup.dump" \
        || { log_re "docker cp failed for db dump"; exit 1; }
    $DOCKER_BIN exec "$DB_CONTAINER" rm -f /tmp/db_backup.dump || true
    log_rs "Database dump saved to $BACKUP_DIR/db_backup.dump"
else
    log_r "No running DB container found – skipping DB backup"
fi

echo "$BACKUP_DIR" > "$BACKUP_DIR/.backup_manifest"
log_rs "Backup complete → $BACKUP_DIR"
'

# ============================================================
# REMOTE HELPER: restore_backup
#   $1 = COMPOSE_DIR          (where docker-compose.yml lives)
#   $2 = RESTORE_BACKUP_DIR   (the backup folder to restore FROM)
# ============================================================
REMOTE_RESTORE_FN="${REMOTE_COMPOSE_HELPER}"'
set -euo pipefail
COMPOSE_DIR="$1"
RESTORE_DIR="$2"
if [ -z "${DOCKER_BIN:-}" ] || [ ! -x "$DOCKER_BIN" ]; then
    if [ -x "/opt/homebrew/bin/docker" ]; then DOCKER_BIN="/opt/homebrew/bin/docker"
    elif command -v docker >/dev/null 2>&1; then DOCKER_BIN="$(command -v docker)"
    else DOCKER_BIN="/usr/bin/docker"; fi
fi

log_r()  { echo "[REMOTE-INFO]    $(date "+%Y-%m-%d %H:%M:%S") - $*"; }
log_re() { echo "[REMOTE-ERROR]   $(date "+%Y-%m-%d %H:%M:%S") - $*" >&2; }
log_rs() { echo "[REMOTE-SUCCESS] $(date "+%Y-%m-%d %H:%M:%S") - $*"; }

# --- Validate backup contents ---
if [ ! -f "$RESTORE_DIR/docker-compose.yml" ]; then
    log_re "No docker-compose.yml found in backup: $RESTORE_DIR"
    exit 1
fi

# --- Stop current containers ---
log_r "Stopping current containers..."
cd "$COMPOSE_DIR"
docker_compose down || { log_re "docker compose down failed during restore"; exit 1; }
log_rs "Containers stopped"

# --- Restore docker-compose.yml ---
cp "$RESTORE_DIR/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml" \
    || { log_re "Failed to restore docker-compose.yml"; exit 1; }
log_rs "docker-compose.yml restored from backup"

# --- Restore .env if it was backed up ---
if [ -f "$RESTORE_DIR/.env" ]; then
    cp "$RESTORE_DIR/.env" "$COMPOSE_DIR/.env" || true
    log_r ".env restored from backup"
fi

# --- DB restore ---
if [ -f "$RESTORE_DIR/db_backup.dump" ]; then
    log_r "Database dump found – starting containers first for DB restore..."

    docker_compose pull 2>/dev/null || true
    docker_compose up -d \
        || { log_re "docker compose up failed before DB restore"; exit 1; }

    log_r "Waiting 15 seconds for DB container to be ready..."
    sleep 15

    DB_CONTAINER=$(docker_compose ps -q postgres 2>/dev/null || true)
    if [ -z "$DB_CONTAINER" ]; then
        DB_CONTAINER=$(docker_compose ps -q db 2>/dev/null || true)
    fi

    if [ -z "$DB_CONTAINER" ]; then
        log_re "Cannot find DB container after bringing compose up – DB NOT restored"
        exit 1
    fi

    DB_USER=$($DOCKER_BIN inspect --format="{{range .Config.Env}}{{println .}}{{end}}" "$DB_CONTAINER" \
        | grep "^POSTGRES_USER=" | cut -d= -f2 || true)
    DB_NAME=$($DOCKER_BIN inspect --format="{{range .Config.Env}}{{println .}}{{end}}" "$DB_CONTAINER" \
        | grep "^POSTGRES_DB=" | cut -d= -f2 || true)

    DB_USER="${DB_USER:-postgres}"
    DB_NAME="${DB_NAME:-app}"

    log_r "Copying dump into DB container and restoring to $DB_NAME..."
    $DOCKER_BIN cp "$RESTORE_DIR/db_backup.dump" "$DB_CONTAINER:/tmp/db_restore.dump" \
        || { log_re "docker cp of db dump into container failed"; exit 1; }

    # Drop connections and restore
    $DOCKER_BIN exec "$DB_CONTAINER" psql -U "$DB_USER" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='\''$DB_NAME'\'' AND pid <> pg_backend_pid();" \
        2>/dev/null || true

    $DOCKER_BIN exec "$DB_CONTAINER" pg_restore \
        -U "$DB_USER" -d "$DB_NAME" --clean --if-exists -F c /tmp/db_restore.dump \
        || { log_re "pg_restore failed"; exit 1; }

    $DOCKER_BIN exec "$DB_CONTAINER" rm -f /tmp/db_restore.dump || true
    log_rs "Database restored from $RESTORE_DIR/db_backup.dump"
else
    log_r "No DB dump in backup – restoring compose only, then starting containers..."
    docker_compose pull 2>/dev/null || true
    docker_compose up -d \
        || { log_re "docker compose up failed after compose restore"; exit 1; }
fi

log_rs "Restore complete"
'

# ============================================================
# FUNCTION: find_latest_backup <domain> (on the remote)
#   Prints the path of the most recent backup folder for domain
# ============================================================
remote_find_latest_backup() {
    local server="$1"
    local domain="$2"
    ssh_cmd "$server" "ls -1dt ${BACKUPS_ROOT}/${domain}_* 2>/dev/null | head -1" || true
}

# ============================================================
# ====================  ROLLBACK MODE  =======================
# ============================================================
run_rollback() {
    local domain="$1"
    local client_name="$2"
    local requested_ts="${3:-}"   # optional – pick specific backup timestamp

    log_step "ROLLBACK MODE — domain: $domain  client: $client_name"

    # -- Locate the backup to restore --
    local restore_backup_dir=""
    if [ -n "$requested_ts" ]; then
        restore_backup_dir="${BACKUPS_ROOT}/${domain}_${requested_ts}"
        log "Using requested backup timestamp: $requested_ts"
        log "Backup path on remote: $restore_backup_dir"

        # Verify it exists
        if ! ssh_cmd "$domain" "[ -d '$restore_backup_dir' ]"; then
            log_error "Requested backup directory does not exist on remote: $restore_backup_dir"
            log_error "Available backups:"
            ssh_cmd "$domain" "ls -1dt ${BACKUPS_ROOT}/${domain}_* 2>/dev/null" || true
            exit 1
        fi
    else
        log "No backup timestamp provided – finding the most recent backup for domain: $domain"
        restore_backup_dir=$(remote_find_latest_backup "$domain" "$domain")

        if [ -z "$restore_backup_dir" ]; then
            log_error "No backups found for domain '$domain' in ${BACKUPS_ROOT}/"
            exit 1
        fi
        log "Most recent backup found: $restore_backup_dir"
    fi

    # -- Show backup contents --
    log "Backup to be restored:"
    ssh_cmd "$domain" "ls -lah '$restore_backup_dir' 2>/dev/null" || true

    # -------------------------------------------------------
    # ROLLBACK STEP 1: Backup the CURRENT state before rolling back
    # -------------------------------------------------------
    log_step "ROLLBACK STEP 1 — Saving current deployment as a rollback-safety backup"
    local rb_ts
    rb_ts=$(date '+%Y%m%d_%H%M%S')
    local rb_safety_dir="${BACKUPS_ROOT}/${domain}_rollback-safety_${rb_ts}"
    log "Safety backup dir on remote: $rb_safety_dir"

    if ssh_script "$domain" "$REMOTE_BACKUP_FN" "'$COMPOSE_REMOTE_PATH'" "'$rb_safety_dir'"; then
        log_success "Current state saved as rollback-safety backup at: $rb_safety_dir"
    else
        log_error "Failed to save rollback-safety backup of current state"
        log_error "Aborting rollback to prevent data loss without a current backup"
        exit 1
    fi

    # -------------------------------------------------------
    # ROLLBACK STEP 2: Restore the previous backup
    # -------------------------------------------------------
    log_step "ROLLBACK STEP 2 — Restoring from backup: $restore_backup_dir"

    if ssh_script "$domain" "$REMOTE_RESTORE_FN" "'$COMPOSE_REMOTE_PATH'" "'$restore_backup_dir'"; then
        log_success "Restore completed successfully from: $restore_backup_dir"
    else
        log_error "Restore FAILED from: $restore_backup_dir"
        log_error "Your rollback-safety backup is preserved at: $rb_safety_dir"
        log_error "Please investigate and restore manually if needed."
        exit 1
    fi

    # -------------------------------------------------------
    # ROLLBACK STEP 3: Health check after rollback
    # -------------------------------------------------------
    log_step "ROLLBACK STEP 3 — Health check after rollback"
    local health_url="http://$DOMAIN:3000/api/health"
    log "Waiting 15 seconds for services to stabilize..."
    sleep 15

    local elapsed=0
    local rollback_healthy=false
    while [ "$elapsed" -lt "$HEALTH_CHECK_TIMEOUT" ]; do
        log "Checking health at: $health_url (elapsed ${elapsed}s)"
        if curl -s -f --max-time 10 "$health_url" > /dev/null 2>&1; then
            log_success "Health check PASSED – rolled-back service is healthy"
            rollback_healthy=true
            break
        fi
        log "Health check not yet passing, retrying in ${HEALTH_CHECK_INTERVAL}s..."
        sleep "$HEALTH_CHECK_INTERVAL"
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
    done

    if [ "$rollback_healthy" = false ]; then
        log_error "Health check FAILED after rollback ($HEALTH_CHECK_TIMEOUT seconds elapsed)"
        log_error "Service may require manual intervention."
        log_error "Rollback-safety backup is available at: $rb_safety_dir"
        exit 1
    fi

    log_step "ROLLBACK COMPLETE"
    log_success "Rollback Summary:"
    log "  - Domain:             $domain"
    log "  - Client:             $client_name"
    log "  - Restored from:      $restore_backup_dir"
    log "  - Safety backup at:   $rb_safety_dir"
    log "  - Health URL:         $health_url"
    exit 0
}

# ============================================================
# ====================  ARGUMENT PARSING  ====================
# ============================================================
ROLLBACK_MODE=false
if [ "${1:-}" = "--rollback" ]; then
    ROLLBACK_MODE=true
    shift
fi

if [ "$ROLLBACK_MODE" = true ]; then
    # --rollback <domain> <client_name> [backup_timestamp]
    if [ $# -lt 2 ]; then
        log_error "Rollback usage: $0 --rollback <domain> <client_name> [backup_timestamp]"
        log_error "  Example: $0 --rollback delta.solvrays.ai clientA"
        log_error "  Example: $0 --rollback delta.solvrays.ai clientA 20260511_143000"
        exit 1
    fi
    DOMAIN="$1"
    CLIENT_NAME="$2"
    ROLLBACK_TS="${3:-}"

    # Test SSH before doing anything
    log_step "TESTING SSH CONNECTIVITY"
    if ssh_cmd "$DOMAIN" "echo 'SSH OK'"; then
        log_success "SSH connection established"
    else
        log_error "Cannot connect to $DOMAIN via SSH"
        exit 1
    fi

    run_rollback "$DOMAIN" "$CLIENT_NAME" "$ROLLBACK_TS"
fi

# ============================================================
# ====================  DEPLOY MODE  =========================
# ============================================================
if [ $# -lt 3 ]; then
    log_error "Deploy usage: $0 <domain> <images> <client_name>"
    log_error "  Example: $0 delta.solvrays.ai \"web,api,worker\" clientA"
    log_error "  Example: $0 beta.solvrays.ai \"all\" clientB"
    log_error ""
    log_error "Rollback usage: $0 --rollback <domain> <client_name> [backup_timestamp]"
    exit 1
fi

DOMAIN="$1"
IMAGES="$2"
CLIENT_NAME="$3"

log "Starting deployment for domain: $DOMAIN"
log "Images to deploy: $IMAGES"
log "Client name: $CLIENT_NAME"

# ------------------------
# PROJECT CONFIGURATION
# ------------------------
DEPLOY_BASE_PATH="$BASE_PROJECTS_DIR/svg-deploy"
PROJECT_PATH="$DEPLOY_BASE_PATH/$CLIENT_NAME"
COMPOSE_FILE="docker-compose.yml"

if [ ! -d "$DEPLOY_BASE_PATH" ]; then
    log_error "Deploy base directory not found: $DEPLOY_BASE_PATH"
    exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
    log_error "Client directory not found: $PROJECT_PATH"
    log_error "Available clients:"
    ls -la "$DEPLOY_BASE_PATH" 2>/dev/null | grep "^d" | awk '{print "  - " $NF}' || true
    exit 1
fi

if [ ! -f "$PROJECT_PATH/$COMPOSE_FILE" ]; then
    log_error "docker-compose file not found: $PROJECT_PATH/$COMPOSE_FILE"
    exit 1
fi

# -------------------------------------------------------
# DEPLOY STEP 1: Pull Latest Code
# -------------------------------------------------------
log_step "DEPLOY STEP 1 — PULLING LATEST CODE"

cd "$PROJECT_PATH" || {
    log_error "Cannot cd to $PROJECT_PATH"
    exit 1
}

log "Pulling latest from origin/$DEFAULT_BRANCH"

if git fetch origin && git checkout "$DEFAULT_BRANCH" && \
   git reset --hard "origin/$DEFAULT_BRANCH" && git clean -fd; then
    log_success "Code pulled successfully"
else
    log_error "Failed to pull latest code"
    exit 1
fi

# -------------------------------------------------------
# DEPLOY STEP 2: SSH Connectivity Test
# -------------------------------------------------------
log_step "DEPLOY STEP 2 — TESTING SSH CONNECTIVITY"
if ssh_cmd "$DOMAIN" "echo 'SSH connection successful'"; then
    log_success "SSH connection established"
else
    log_error "Failed to connect to server via SSH: $DOMAIN"
    exit 1
fi

# -------------------------------------------------------
# DEPLOY STEP 3: Backup Current Deployment (compose + DB)
# -------------------------------------------------------
log_step "DEPLOY STEP 3 — BACKING UP CURRENT DEPLOYMENT"
BACKUP_TS=$(date '+%Y%m%d_%H%M%S')
BACKUP_DIR="${BACKUPS_ROOT}/${DOMAIN}_${BACKUP_TS}"
log "Backup directory on remote: $BACKUP_DIR"

if ssh_script "$DOMAIN" "$REMOTE_BACKUP_FN" "'$COMPOSE_REMOTE_PATH'" "'$BACKUP_DIR'"; then
    log_success "Pre-deployment backup completed → $BACKUP_DIR"
else
    log_error "Failed to complete pre-deployment backup"
    exit 1
fi

# -------------------------------------------------------
# DEPLOY STEP 4: Sync project (compose + build context + bind-mount sources)
# -------------------------------------------------------
log_step "DEPLOY STEP 4 — SYNCING PROJECT TO SERVER"
log "Source:      $PROJECT_PATH/"
log "Destination: $DOMAIN:$COMPOSE_REMOTE_PATH/"
log "Excludes:    node_modules, .git, .next, dist (rsync; remote backups/ not deleted)"

if rsync_project_to_remote "$DOMAIN" "$PROJECT_PATH" "$COMPOSE_REMOTE_PATH"; then
    log_success "Project synced to server (includes docker-compose.yml and Dockerfile)"
else
    log_error "Failed to rsync project to server (need rsync locally and on the SSH host)"
    exit 1
fi

# -------------------------------------------------------
# DEPLOY STEP 5: Stop Containers
# -------------------------------------------------------
log_step "DEPLOY STEP 5 — STOPPING CONTAINERS"
if remote_with_compose "$DOMAIN" "cd '$COMPOSE_REMOTE_PATH' && docker_compose down"; then
    log_success "Containers stopped successfully"
else
    log_error "Failed to stop containers"
    exit 1
fi

# -------------------------------------------------------
# DEPLOY STEP 6: Remove Old Images
# -------------------------------------------------------
log_step "DEPLOY STEP 6 — DELETING OLD IMAGES"

if [ "$IMAGES" = "all" ]; then
    log "Removing all project images from compose file"
    ssh_cmd "$DOMAIN" "cd $COMPOSE_REMOTE_PATH && \
        images=\$(grep -E 'image:' docker-compose.yml | sed 's/.*image:\s*//' | sed 's/\s*$//' | sort -u); \
        for img in \$images; do \
            echo \"Removing image: \$img\"; \
            $DOCKER_BIN rmi \$img 2>/dev/null || true; \
        done"
else
    log "Removing specific images: $IMAGES"
    images_to_remove=$(echo "$IMAGES" | tr ',' ' ')
    for img in $images_to_remove; do
        log "Removing image: $img"
        ssh_cmd "$DOMAIN" "$DOCKER_BIN rmi $img 2>/dev/null || true"
    done
fi
log_success "Old images removed"

# -------------------------------------------------------
# DEPLOY STEP 7: Pull New Images
# -------------------------------------------------------
log_step "DEPLOY STEP 7 — PULLING NEW IMAGES"
if remote_with_compose "$DOMAIN" "cd '$COMPOSE_REMOTE_PATH' && DOCKER_CONFIG=/tmp docker_compose pull"; then
    log_success "New images pulled successfully"
else
    log_error "Failed to pull new images"
    exit 1
fi

# -------------------------------------------------------
# DEPLOY STEP 8: Start Containers
# -------------------------------------------------------
log_step "DEPLOY STEP 8 — STARTING CONTAINERS"
if remote_with_compose "$DOMAIN" "cd '$COMPOSE_REMOTE_PATH' && docker_compose up -d"; then
    log_success "Containers started successfully"
else
    log_error "Failed to start containers"
    exit 1
fi

# -------------------------------------------------------
# DEPLOY STEP 9: Health Check (auto-rollback on failure)
# -------------------------------------------------------
log_step "DEPLOY STEP 9 — HEALTH CHECK"
log "Waiting 10 seconds for containers to initialize..."
sleep 10

health_url="http://$DOMAIN/api/health"
elapsed=0
deploy_healthy=false

while [ "$elapsed" -lt "$HEALTH_CHECK_TIMEOUT" ]; do
    log "Checking health at: $health_url (attempt $((elapsed / HEALTH_CHECK_INTERVAL + 1)))"
    if curl -s -f --max-time 10 "$health_url" > /dev/null 2>&1; then
        log_success "Health check PASSED – service is healthy"
        deploy_healthy=true
        break
    fi
    log "Health check not yet passing, retrying in ${HEALTH_CHECK_INTERVAL}s..."
    sleep "$HEALTH_CHECK_INTERVAL"
    elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
done

if [ "$deploy_healthy" = false ]; then
    log_error "Health check FAILED after ${HEALTH_CHECK_TIMEOUT}s – triggering automatic rollback"
    log_error "Restoring from pre-deployment backup: $BACKUP_DIR"

    if ssh_script "$DOMAIN" "$REMOTE_RESTORE_FN" "'$COMPOSE_REMOTE_PATH'" "'$BACKUP_DIR'"; then
        log_success "Automatic rollback completed – previous version restored"
    else
        log_error "AUTOMATIC ROLLBACK ALSO FAILED – manual intervention required"
        log_error "Pre-deployment backup is at: $BACKUP_DIR"
    fi
    exit 1
fi

# ============================================================
# DEPLOYMENT COMPLETE
# ============================================================
log_step "DEPLOYMENT COMPLETE"
log_success "Summary:"
log "  - Domain:         $DOMAIN"
log "  - Images:         $IMAGES"
log "  - Client:         $CLIENT_NAME"
log "  - Project path:   $PROJECT_PATH"
log "  - Backup at:      $BACKUP_DIR"
log "  - Health URL:     $health_url"
log ""
log "To rollback this deployment run:"
log "  $0 --rollback $DOMAIN $CLIENT_NAME $BACKUP_TS"