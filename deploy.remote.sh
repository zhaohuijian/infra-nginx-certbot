#!/usr/bin/env bash
set -euo pipefail

# deploy — 部署入口，供 sudo /usr/local/bin/deploy [DIR] 调用
#
# 用法：deploy [ DIR ]
#   DIR  部署目录，含 docker-compose.yml；默认 /opt/apps/nginx_certbot
#
# 约定：本脚本部署到服务器后安装为 /usr/local/bin/deploy，本地执行 local.deploy.sh 即可自动化部署

if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi
APP_NAME="nginx-certbot"
DEFAULT_APP_DIR="/opt/apps/nginx_certbot"

if [[ $# -eq 0 ]]; then
  APP_DIR="$DEFAULT_APP_DIR"
elif [[ $# -eq 1 ]]; then
  APP_DIR="$1"
else
  echo "Error: 仅支持 0 或 1 个参数，见 -h" >&2
  usage >&2
  exit 1
fi

COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

log() {
  echo "[deploy][$APP_NAME][$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

if [[ ! -f "$COMPOSE_FILE" ]]; then
  log "Error: docker-compose file '$COMPOSE_FILE' does not exist." >&2
  exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
  log "Error: app directory '$APP_DIR' does not exist." >&2
  exit 1
fi

cd "$APP_DIR"

log "Pull images"
docker compose -f "$COMPOSE_FILE" pull
if ! docker compose -f "$COMPOSE_FILE" exec nginx nginx -t; then
  log "Nginx config is invalid"
  exit 1
fi
docker compose -f "$COMPOSE_FILE" down || true
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
log "Deploy finished"
docker compose -f "$COMPOSE_FILE" ps