#!/usr/bin/env bash
# 为指定域名首次申请 Let's Encrypt 证书（webroot 模式）
# 使用前请确保：1) 站点已在 nginx conf.d 中配置 80 与 /.well-known/acme-challenge/；2) nginx 已启动；3) 域名 DNS 已指向本机。
# 用法: ./init-cert.sh --domain example.com [--domain www.example.com] [--staging] [--email your@email.com]
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERTBOT_CONF="${REPO_ROOT}/certbot/conf"
CERTBOT_WWW="${REPO_ROOT}/certbot/www"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"

DOMAINS=()
STAGING=""
EMAIL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain)
      DOMAINS+=("$2")
      shift 2
      ;;
    --staging)
      STAGING="--staging"
      shift
      ;;
    --email)
      EMAIL="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1"
      exit 1
      ;;
  esac
done

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "用法: $0 --domain <域名> [--domain <域名2> ...] [--staging] [--email your@email.com]"
  echo "示例: $0 --domain nextdemo.zhaohuijian.com --email admin@example.com"
  exit 1
fi

# 确保 DH 参数存在（Nginx 需要）
"$SCRIPT_DIR/ensure-ssl-params.sh"

# 使用 compose 中 certbot 服务的镜像与卷，保持单一事实来源；覆盖 entrypoint 执行一次性 certonly
DOMAIN_ARGS=()
for d in "${DOMAINS[@]}"; do
  DOMAIN_ARGS+=(-d "$d")
done

EMAIL_ARGS=()
[[ -n "$EMAIL" ]] && EMAIL_ARGS=(--email "$EMAIL")

docker compose -f "$COMPOSE_FILE" run --rm \
  --entrypoint certbot \
  certbot \
  certonly --webroot -w /var/www/certbot \
  "${DOMAIN_ARGS[@]}" \
  "${EMAIL_ARGS[@]}" \
  --agree-tos \
  --no-eff-email \
  $STAGING

echo "[ok] 证书已签发。若使用 staging，确认无误后请去掉 --staging 再申请正式证书。"
echo "     Nginx 重载以加载新证书: docker compose -f $COMPOSE_FILE exec nginx nginx -s reload"
