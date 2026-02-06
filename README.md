# Nginx + Certbot 多站点基础设施

基于 Docker Compose 的 Nginx 反向代理 + Let's Encrypt 证书自动化，支持多站点与 GitOps 管理。

## 特性

- **多站点**：`nginx/conf.d/*.conf` 一文件一站点，按需扩展
- **证书自动化**：Certbot 容器内每 12 小时续期；可选宿主机 cron 执行续期并重载 Nginx
- **GitOps 友好**：站点配置、SSL 选项、Compose 均进 Git，变更可追溯
- **企业向**：健康检查、资源限制、SSL 配置版本化、文档与脚本齐全

## 目录结构

```
├── docker-compose.yml       # 服务定义
├── .env.example             # 环境变量示例（复制为 .env）
├── nginx/
│   ├── nginx.conf           # 主配置
│   ├── ssl/                 # Certbot 推荐的 TLS 参数（Git 管理，可脚本从官方拉取）
│   │   ├── options-ssl-nginx.conf
│   │   └── ssl-dhparams.pem
│   └── conf.d/              # 站点配置，仅放 *.conf
├── certbot/
│   ├── conf/                # 证书（持久化）
│   └── www/                 # ACME 验证根目录
├── scripts/
│   ├── ensure-ssl-params.sh # 缺失时从 Certbot 官方下载 options-ssl-nginx.conf、ssl-dhparams.pem 到 nginx/ssl
│   ├── init-cert.sh         # 为新域名首次申请证书
│   └── renew-and-reload.sh  # 续期并重载 Nginx（可选 cron）
└── docs/
    └── DESIGN.md            # 设计与 GitOps 说明
```

## 快速开始

### 1. 准备环境

```bash
cp .env.example .env
# 按需编辑 .env 中的静态站点路径（若暂无静态站可先保持默认，确保目录存在或见下方“新增站点”）
```

### 2. 确保 TLS 参数就绪（首次或缺失时从 Certbot 官方下载到 nginx/ssl）

```bash
./scripts/ensure-ssl-params.sh
```

### 3. 启动服务

```bash
docker compose up -d
```

### 4. 为新域名申请证书（首次）

确保该域名已在 `nginx/conf.d/` 中有对应 `*.conf`，且 80 端口由本 Nginx 接管、DNS 已指向本机后：

```bash
# 正式证书（建议先用 --staging 测试）
./scripts/init-cert.sh --domain your.example.com --email admin@example.com

# 或 Staging 测试（不占正式限额）
./scripts/init-cert.sh --domain your.example.com --email admin@example.com --staging
```

申请成功后重载 Nginx 使证书生效：

```bash
docker compose exec nginx nginx -s reload
```

## GitOps：新增站点流程

1. **在仓库中新增配置**  
   在 `nginx/conf.d/` 下新建 `你的域名.conf`，参考现有配置：
   - 80：`server_name`、`/.well-known/acme-challenge/`、跳转 HTTPS
   - 443：`ssl_certificate` / `ssl_certificate_key` 指向 `/etc/letsencrypt/live/你的域名/`，`include` 与 `ssl_dhparam` 同现有站点

2. **若为静态站点**  
   在 `docker-compose.yml` 的 nginx volumes 中增加挂载，并在 `.env` 中配置对应路径（或使用默认路径并确保主机目录存在）。

3. **提交并推送**，在服务器上：
   ```bash
   git pull
   ./scripts/ensure-ssl-params.sh   # 若尚未执行过
   ./scripts/init-cert.sh --domain 你的域名 --email your@email.com
   docker compose up -d
   docker compose exec nginx nginx -s reload
   ```

4. **后续仅改配置时**：`git pull` 后执行 `docker compose exec nginx nginx -s reload` 即可。

## 证书续期

- **默认（已联动）**：Certbot 容器内每 12 小时执行 `certbot renew`，**续期成功后会写入触发器**，Nginx 在约 60 秒内检测到并执行 `nginx -s reload`，无需等待最多 6 小时。同时 Nginx 仍保留每 6 小时兜底重载。
- **可选**：若希望用宿主机 cron 统一控制续期时间（例如每天 3:00），可使用 `scripts/renew-and-reload.sh`；此时可停止 certbot 容器，避免与 cron 重复续期。

## CI/CD 部署（GitHub Actions）

推送 `main` 分支或手动触发工作流后，Runner 先 **checkout 代码**，再用 **rsync** 同步到远端服务器（排除 `.git`、`certbot/conf`、`certbot/www`，不覆盖服务器上的证书与 ACME 数据），最后 SSH 执行 `docker compose up -d`。服务器无需能访问 GitHub。

### 配置要求

1. **仓库 Secrets**（Settings → Secrets and variables → Actions）  
   - `SSH_PRIVATE_KEY`：deploy 用户私钥完整内容（含 `-----BEGIN ... PRIVATE KEY-----` 与 `-----END ... PRIVATE KEY-----`）。  
   - `DEPLOY_HOST`：服务器 IP 或域名。

2. **可选 Variables**（同上 → Variables）  
   - `DEPLOY_USER`：SSH 用户名，默认 `deploy`。  
   - `DEPLOY_PORT`：SSH 端口，默认 `22`。  
   - `REPO_PATH`：服务器上部署目录（同步后的项目根路径），默认 `~/infra-nginx-certbot`。

3. **服务器准备**  
   - 已安装 Docker 与 Docker Compose，deploy 用户能执行 `docker compose`（如加入 `docker` 组）。  
   - 无需在服务器上预先 clone 仓库；首次部署时目录可由 rsync 自动创建，`certbot/conf`、`certbot/www` 会在部署步骤中创建并持久保留。  
   - 若默认分支非 `main`，需在 `.github/workflows/deploy.yml` 中把 `branches: [main]` 改为对应分支名。

## 常用命令

| 说明 | 命令 |
|------|------|
| 查看证书列表 | `docker compose exec certbot certbot certificates` |
| 重载 Nginx 配置 | `docker compose exec nginx nginx -s reload` |
| 测试 Nginx 配置 | `docker compose exec nginx nginx -t` |
| 查看 Nginx 日志 | `docker compose logs -f nginx` |

## 安全与运维说明

- **certbot/conf** 内含私钥，勿提交到公开仓库；权限建议限制为当前运行用户。
- 首次为新域名申请建议使用 `--staging`，确认无误后再申请正式证书，避免触发 Let's Encrypt 限频。
- 详细设计、证书生命周期与 GitOps 约定见 [docs/DESIGN.md](docs/DESIGN.md)。

## 许可证

MIT 
