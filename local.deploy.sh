#!/usr/bin/env bash

set -euo pipefail

# local.deploy.sh — 本地同步并触发远端 deploy
#
# 用法：
#   ./local.deploy.sh <user@host> <ssh_key_path> [ -p PORT ] [ --path DIR ]
#
# 必填：
#   user@host    远程登录目标，如 deploy@example.com
#   ssh_key_path 私钥路径，如 ~/.ssh/server.deploy
#
# 可选（为空时使用脚本内默认值）：
#   -p, --port PORT  SSH 端口，默认见 DEFAULT_REMOTE_PORT
#   --path DIR       远端部署目录，默认见 DEFAULT_DEPLOY_DIR
#
# 示例：
#   ./local.deploy.sh deploy@server.com ~/.ssh/server.deploy
#   ./local.deploy.sh deploy@server.com ~/.ssh/server.deploy -p 10022
#   ./local.deploy.sh deploy@server.com ~/.ssh/server.deploy --path /opt/apps/nginx_certbot
#   ./local.deploy.sh deploy@server.com ~/.ssh/server.deploy -p 10022 --path /opt/apps/nginx_certbot

DEFAULT_LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)" # 本地项目根目录
DEFAULT_DEPLOY_DIR="/opt/apps/nginx_certbot" # 远端部署目录
DEFAULT_REMOTE_PORT="22" # 远端 SSH 端口

usage() {
  sed -n '5,22p' "$0" | sed 's/^# *//'
  echo ""
  echo "当前默认："
  echo "  DEFAULT_DEPLOY_DIR=$DEFAULT_DEPLOY_DIR"
  echo "  DEFAULT_REMOTE_PORT=$DEFAULT_REMOTE_PORT"
}

REMOTE_PORT="$DEFAULT_REMOTE_PORT" # 远端 SSH 端口
DEPLOY_PATH_RAW="$DEFAULT_DEPLOY_DIR" # 远端部署目录
POSITIONALS=() # 位置参数

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      # 可省略取值，省略则用默认端口
      if [[ $# -ge 2 && -n "${2:-}" && "${2}" != -* ]]; then REMOTE_PORT="$2"; shift 2; else shift 1; fi
      ;;
    --path)
      if [[ $# -ge 2 && -n "${2:-}" && "${2}" != -* ]]; then DEPLOY_PATH_RAW="$2"; shift 2; else shift 1; fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Error: 未知选项 $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONALS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONALS[@]} -lt 2 ]]; then
  echo "Error: 缺少必填参数 <user@host> 或 <ssh_key_path>" >&2
  usage >&2
  exit 1
fi
if [[ ${#POSITIONALS[@]} -gt 2 ]]; then
  echo "Error: 多余参数: ${POSITIONALS[*]:2}" >&2
  usage >&2
  exit 1
fi

REMOTE_TARGET="${POSITIONALS[0]}" # deploy@server.com
SSH_KEY_RAW="${POSITIONALS[1]}" # ~/.ssh/server.deploy
REMOTE_USER="${REMOTE_TARGET%%@*}" # deploy
REMOTE_HOST="${REMOTE_TARGET#*@}" # server.com

if [[ "$REMOTE_USER" == "$REMOTE_TARGET" ]] || [[ -z "$REMOTE_HOST" ]]; then
  echo "Error: user@host 格式不正确: $REMOTE_TARGET" >&2
  exit 1
fi

LOCAL_DIR="${LOCAL_DIR:-$DEFAULT_LOCAL_DIR}"

# 展开并校验 SSH key
SSH_KEY_PATH=$(eval echo "$SSH_KEY_RAW")
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "Error: SSH key not found at $SSH_KEY_PATH" >&2
  exit 1
fi

if [[ ! -d "$LOCAL_DIR" ]]; then
  echo "Error: Local directory '$LOCAL_DIR' does not exist." >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "Error: rsync is required. Install rsync and retry." >&2
  exit 1
fi

echo "🔎 Local dir: $LOCAL_DIR"
echo "🔁 Remote: $REMOTE_USER@$REMOTE_HOST (port $REMOTE_PORT)"
echo "📁 Deploy path: $DEPLOY_PATH_RAW"

echo "➡️  同步文件到远端（排除 .git、certbot、deploy.sh 等）..."
rsync -avvz \
  --exclude '.git' \
  --exclude '.DS_Store*' \
  --exclude '.github*' \
  --exclude '.env*' \
  --exclude '.gitignore' \
  --exclude 'certbot*' \
  --exclude 'local.deploy.sh' \
  --exclude 'readme.md' \
  -e "ssh -i $SSH_KEY_PATH -p $REMOTE_PORT -o StrictHostKeyChecking=accept-new" \
  "$LOCAL_DIR/" "$REMOTE_USER@$REMOTE_HOST:${DEPLOY_PATH_RAW}/"

echo "➡️  在远端执行部署脚本..."
ssh -i "$SSH_KEY_PATH" -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_HOST" \
  "DEPLOY_PATH_RAW='${DEPLOY_PATH_RAW}' bash -s" <<'REMOTE_DEPLOY'
set -e
echo "🚀 开始远程部署..."
if ! sudo -n /usr/local/bin/deploy nginx-certbot; then
  echo "❌ 部署失败，请查看上方日志（若为容器启动失败，可检查 certbot 目录或磁盘空间）" >&2
  exit 1
fi
echo "✅ 远程部署脚本执行完成"
REMOTE_DEPLOY

echo "✅ 部署完成"
