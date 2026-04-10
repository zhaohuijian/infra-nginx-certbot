# 智师汇 · Nginx + Certbot 反向代理基础设施

基于 Docker Compose 的 **Nginx 反向代理 + Let's Encrypt 证书自动化**，支持多站点配置与 GitOps 管理。

## 架构概览

```
外部流量（80 / 443）
        │
        ▼
  ┌─────────────────┐
  │   nginx-proxy   │  nginx:1.28.2-alpine
  │                 │  ├── 80  → ACME 验证 + 跳转 HTTPS
  │                 │  ├── 443 → 反向代理各业务服务
  │                 │  └── 81  → 健康检查（内部）
  └────────┬────────┘
           │ proxy-internal 网络
           ├──▶ project-demo:3000
           └──▶ ... (其他服务按需添加)

  ┌─────────────────┐
  │    certbot      │  certbot/certbot:v5.3.0
  │                 │  每 12 小时执行 certbot renew
  │                 │  续期成功后写 reload.flag
  └─────────────────┘
           │ reload.flag（共享 Docker Volume）
           ▼
  nginx 每 60 秒检测 flag → nginx -t → nginx -s reload
```

**关键设计**：证书续期与 Nginx 重载通过 **共享 Volume 中的触发器文件** 解耦，无需容器间 SSH 或特权操作。

---

## 目录结构

```
├── docker-compose.yml              # 服务定义（nginx + certbot + 共享卷）
├── nginx/
│   ├── nginx.conf                  # 主配置
│   ├── ssl/                        # TLS 参数（Git 管理）
│   │   ├── options-ssl-nginx.conf  # Certbot 推荐的 SSL 配置
│   │   └── ssl-dhparams.pem        # DH 参数（2048位）
│   └── conf.d/                     # 站点配置，每域名一个 *.conf
│       ├── health.conf             # 内部健康检查（81端口 /health）
│       └── demo.zhaohuijian.com.conf  # 站点配置示例
├── certbot/
│   ├── conf/                       # 证书持久化目录（.gitkeep，勿提交内容）
│   └── www/                        # ACME 验证根目录（.gitkeep）
├── scripts/
│   ├── ensure-ssl-params.sh        # 首次缺失时从 Certbot 官方下载 TLS 参数
│   ├── init-cert.sh                # 为新域名首次申请证书（webroot 模式）
│   └── renew-and-reload.sh         # 可选：宿主机 cron 手动续期
├── local.deploy.sh                 # 本地手动同步并触发远端部署的脚本
├── deploy.remote.sh                # 服务器侧部署脚本（安装为 /usr/local/bin/deploy）
└── .github/workflows/deploy.yml   # GitHub Actions 自动部署（手动触发）
```

---

## 快速开始

### 前置条件

- 服务器已安装 Docker 与 Docker Compose
- 域名 DNS 已解析到服务器 IP（证书申请时必须）
- 已创建 `proxy-internal` Docker 网络（业务服务容器共享此网络与 Nginx 通信）

```bash
docker network create proxy-internal
```

### 1. 确保 TLS 参数就绪

```bash
./scripts/ensure-ssl-params.sh
```

首次部署或 `nginx/ssl/` 文件缺失时，从 Certbot 官方下载 `options-ssl-nginx.conf` 与 `ssl-dhparams.pem`。

### 2. 启动服务

```bash
docker compose up -d
```

启动后可验证：

```bash
docker compose ps
curl http://localhost:81/health   # 返回 "ok" 则 Nginx 正常
```

### 3. 首次申请域名证书

确认域名已在 `nginx/conf.d/` 有对应配置、DNS 指向本机、80 端口已由 Nginx 接管后：

```bash
# 建议先用 --staging 测试（不占正式申请次数限额）
./scripts/init-cert.sh --domain msh.zhaohuijian.com --email admin@example.com --staging

# 测试无误后申请正式证书
./scripts/init-cert.sh --domain msh.zhaohuijian.com --email admin@example.com
```

申请成功后重载 Nginx：

```bash
docker compose exec nginx nginx -s reload
```

---

## 新增站点（GitOps 流程）

### 第一步：添加 Nginx 站点配置

在 `nginx/conf.d/` 下新建 `你的域名.conf`，参考 `demo.zhaohuijian.com.conf`：

```nginx
# 80：ACME 验证 + 强制跳转 HTTPS
server {
    listen 80;
    server_name 你的域名.com;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files $uri =404;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# 443：HTTPS 反向代理
server {
    listen 443 ssl;
    http2 on;
    server_name 你的域名.com;

    ssl_certificate     /etc/letsencrypt/live/你的域名.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/你的域名.com/privkey.pem;
    include /etc/nginx/ssl-params/options-ssl-nginx.conf;
    ssl_dhparam /etc/nginx/ssl-params/ssl-dhparams.pem;

    location / {
        proxy_pass http://服务容器名:端口;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

> **Next.js / Better Auth 应用注意**：认证库在某些会话场景下会返回较大响应头（多条 Set-Cookie），需调大 proxy buffer，参考 `msh.zhaohuijian.com.conf` 中的配置，避免偶发 502。

### 第二步：提交并部署

```bash
git add nginx/conf.d/你的域名.com.conf
git commit -m "feat(nginx): 新增 你的域名.com 站点配置"
git push
```

在服务器上（或通过 CI/CD 自动触发）：

```bash
./scripts/init-cert.sh --domain 你的域名.com --email your@email.com
docker compose up -d
docker compose exec nginx nginx -s reload
```

### 后续仅修改配置

```bash
git pull
docker compose exec nginx nginx -t        # 先校验，避免带病重载
docker compose exec nginx nginx -s reload
```

---

## 证书自动续期

续期机制完全容器内自洽，无需额外 cron：

```
certbot 容器（每 12h 执行 certbot renew）
    │
    │ 仅续期成功时执行 deploy-hook
    ▼
touch /var/run/certbot-reload/reload.flag   ← Docker Volume 共享
    
nginx 容器（每 60s 检测 flag）
    │
    ├── 检测到 flag → nginx -t → 通过 → nginx -s reload → 删除 flag
    └── nginx -t 失败 → 打印日志，不删 flag，等待人工修复
```

- Certbot 容器续期成功后写 flag，Nginx 在约 60 秒内重载。
- `nginx -t` 守护 reload 质量：配置有误时不执行重载，保留 flag 便于排查。
- **可选**：若改用宿主机 cron 统一控制续期时间，可停止 certbot 容器，使用 `scripts/renew-and-reload.sh`。

---

## 部署方式

本项目提供三种部署方式，按场景选择：

### 方式一：GitHub Actions 自动部署（推荐生产环境）

工作流文件：`.github/workflows/deploy.yml`

当前配置为**手动触发**（`workflow_dispatch`），需在 GitHub 仓库页面点击「Run workflow」启动。

> 如需改为推送 main 分支自动触发，取消 `deploy.yml` 中 `push` 相关行的注释即可。

**工作流步骤：**

```
Runner checkout 代码
    ↓
rsync 同步到服务器（排除 .git、certbot/conf、certbot/www）
    ↓
SSH 登录服务器执行：
    mkdir -p certbot/conf certbot/www
    ./scripts/ensure-ssl-params.sh
    docker compose pull
    docker compose up -d
```

**需在仓库 Settings → Secrets and variables → Actions 配置：**

| 类型 | 名称 | 说明 |
|------|------|------|
| Secret | `SSH_PRIVATE_KEY` | deploy 用户 SSH 私钥完整内容（含 `-----BEGIN/END-----`） |
| Variable | `DEPLOY_HOST` | 服务器 IP 或域名 |
| Variable | `DEPLOY_USER` | SSH 用户名，默认 `deploy` |
| Variable | `DEPLOY_PORT` | SSH 端口，默认 `22` |
| Variable | `REPO_PATH` | 服务器上部署目录，默认 `~/infra-nginx-certbot` |

---

### 方式二：本地手动部署（快速调试 / 无 CI 时）

`local.deploy.sh` 在本地执行 rsync + SSH 远端部署，无需 GitHub Actions：

```bash
# 基本用法
./local.deploy.sh deploy@your-server.com ~/.ssh/your_key

# 指定非标准 SSH 端口
./local.deploy.sh deploy@your-server.com ~/.ssh/your_key -p 10022

# 指定服务器部署目录
./local.deploy.sh deploy@your-server.com ~/.ssh/your_key --path /opt/apps/nginx_certbot

# 查看帮助
./local.deploy.sh --help
```

脚本会自动执行：
1. rsync 同步（排除 `.git`、`.env`、`certbot/` 等）
2. SSH 登录服务器，调用 `sudo -n /usr/local/bin/deploy nginx-certbot` 执行部署

---

### 方式三：服务器侧部署脚本（供前两种方式调用）

`deploy.remote.sh` 是服务器侧的部署入口，部署时安装为 `/usr/local/lib/deploy/apps/nginx-certbot.sh`，通过 `sudo /usr/local/bin/deploy nginx-certbot` 调用。

**执行逻辑：**

1. 确保 `certbot/conf`、`certbot/www` 目录存在（权限 755）
2. `docker compose pull`（拉取最新镜像）
3. `docker compose run --rm nginx nginx -t`（**先校验配置**，配置无效则中止部署）
4. `docker compose down && docker compose up -d --remove-orphans`
5. 打印容器状态

---

## 常用命令

| 说明 | 命令 |
|------|------|
| 查看容器状态 | `docker compose ps` |
| 健康检查 | `curl http://localhost:81/health` |
| 测试 Nginx 配置 | `docker compose exec nginx nginx -t` |
| 重载 Nginx 配置 | `docker compose exec nginx nginx -s reload` |
| 查看 Nginx 日志 | `docker compose logs -f nginx` |
| 查看 Certbot 日志 | `docker compose logs -f certbot` |
| 查看证书列表 | `docker compose exec certbot certbot certificates` |
| 手动触发续期测试 | `docker compose exec certbot certbot renew --dry-run` |
| 重建容器 | `docker compose up -d --force-recreate` |

---

## 安全与运维注意事项

- **`certbot/conf/` 内含私钥**，已在 `.gitignore` 中排除，切勿提交到任何仓库（含私有库）。
- **首次申请证书务必先用 `--staging`**，确认流程无误后再申请正式证书，避免触发 Let's Encrypt [频率限制](https://letsencrypt.org/docs/rate-limits/)（同域每周最多 5 次正式申请）。
- 部署脚本中的 `nginx -t` 校验是**硬性守护**，配置有语法错误时会中止部署，保护生产环境不因配置错误导致 Nginx 崩溃。
- `proxy-internal` 网络为外部网络（`external: true`），需提前在服务器上创建，并确保所有业务容器也挂载此网络，才能通过容器名互相访问。

---

© 2026 慧见
