# Nginx + Certbot 基础设施：设计与 GitOps 实践

## 一、项目定位与目标

本项目作为 **Nginx + Certbot 容器化部署的基础设施**，目标包括：

- **多站点**：通过 `conf.d/*.conf` 支持任意数量站点，每站点一个配置文件。
- **GitOps 管理**：站点配置、SSL 选项、Compose 定义均纳入 Git，变更通过提交 → 拉取 → 重载生效。
- **企业实践**：证书申请/续期自动化、配置规范、可观测性、安全与资源约束。

---

## 二、当前架构分析

### 2.1 已有能力（优点）

| 能力 | 说明 |
|------|------|
| 双服务编排 | `docker-compose` 中 nginx + certbot 分离，职责清晰。 |
| 证书持久化 | `certbot/conf`、`certbot/www` 挂载，数据不随容器销毁。 |
| 自动续期 | certbot 容器内每 12 小时执行 `certbot renew --webroot`。 |
| 配置重载 | nginx 每 6 小时 `nginx -s reload`，可加载新证书。 |
| ACME 验证 | 各站点 80 端口均暴露 `/.well-known/acme-challenge/` 给 certbot。 |
| 多站点 | 通过 `include conf.d/*.conf` 支持多 vhost。 |

### 2.2 待改进点

| 问题 | 影响 | 改进方向 |
|------|------|----------|
| **首次证书未自动化** | 新站点需手动执行 certbot 命令 | 提供 `scripts/init-cert.sh`，支持按域名首次申请。 |
| **证书续期与 Nginx 重载未联动** | 续期后可能延迟最多 6h 才重载 | 已通过共享卷触发器实现：续期成功后写标记，Nginx 约 60s 内重载。 |
| **SSL 依赖未版本化** | `options-ssl-nginx.conf`、`ssl-dhparams.pem` 未在仓库中管理 | 将 options 纳入 Git，dhparams 由脚本生成并落盘。 |
| **站点配置命名不统一** | `enos.zhaohuijian.com` 无 `.conf` 后缀 | 统一为 `*.conf`，避免遗漏或歧义。 |
| **主机路径硬编码** | `/var/www/dare...` 等写死在 compose | 通过 `.env` 或约定目录 + 文档，便于不同环境。 |
| **缺少健康检查** | 容器异常不易被发现 | 为 nginx/certbot 增加 healthcheck。 |
| **无 GitOps 文档** | 新增站点、证书流程不清晰 | README + 本文档明确“加站、申请证书、续期”流程。 |

### 2.3 证书生命周期

```
新站点
  → 在 conf.d 添加 xxx.conf（80 + 443/8443）
  → 运行 scripts/init-cert.sh --domain xxx.example.com
  → certbot certonly --webroot，证书写入 certbot/conf
  → 启动/重载 nginx，HTTPS 生效

运行中
  → certbot 容器每 12h 执行 renew
  → 若续期成功，应触发 nginx reload（见实现方案）

续期失败
  → 依赖日志与监控告警，人工介入或修复后重跑 renew
```

---

## 三、GitOps 工作流设计

### 3.1 原则

- **配置即代码**：所有站点 `conf.d/*.conf`、`nginx.conf`、`options-ssl-nginx.conf`、`docker-compose.yml` 均进 Git。
- **单一事实来源**：生产环境通过 `git pull` 获取配置，再执行 `docker compose up -d` 或 `nginx -s reload`（仅 nginx 配置变更时）。
- **不可变基础设施**：不登录容器改配置；改完本地测试后提交，再在服务器拉取并应用。

### 3.2 新增站点流程（GitOps）

1. **在仓库中**  
   - 在 `nginx/conf.d/` 下新增 `站点域名.conf`（参考现有模板）。  
   - 如需静态资源，在文档或 `.env.example` 中说明主机目录与挂载关系。  
   - 提交并推送。

2. **在服务器上**  
   - `git pull`  
   - 若为新域名：先执行 `scripts/init-cert.sh --domain 站点域名`（确保 80 已由本 nginx 接管）。  
   - `docker compose up -d`（若未起）或 `docker compose exec nginx nginx -s reload`（仅改配置时）。  
   - 可选：通过 CI/CD 在指定分支 push 后自动执行 pull + init-cert + reload。

### 3.3 证书续期与 Nginx 联动

- **现状**：certbot 每 12h 续期；nginx 每 6h reload，二者独立。  
- **实现**：续期成功后由 certbot 写入共享卷 `certbot-reload-trigger` 下的标记文件；Nginx 侧每 60 秒检查该文件，若存在则执行 `nginx -s reload` 并删除标记。这样无需挂载 Docker socket，且续期后约 1 分钟内即可加载新证书。同时保留 Nginx 每 6 小时兜底重载。

---

## 四、目录与文件规范

```
infra-nginx-certbot/
├── docker-compose.yml      # 服务定义，尽量用 .env 替代硬编码路径
├── .env.example            # 环境变量示例（域名列表、路径等）
├── README.md               # 快速开始、GitOps 流程、常见问题
├── docs/
│   └── DESIGN.md           # 本设计文档
├── nginx/
│   ├── nginx.conf          # 主配置，include conf.d
│   ├── ssl/
│   │   └── options-ssl-nginx.conf   # 纳入 Git 的 SSL 选项
│   └── conf.d/
│       └── *.conf          # 每站点一个，命名：<域名>.conf 或 <服务名>.conf
├── certbot/
│   ├── conf/               # 证书与 dhparams（持久化，部分不提交）
│   │   └── ssl-dhparams.pem   # 由脚本生成
│   └── www/                # ACME 验证根目录（持久化）
└── scripts/
    ├── init-cert.sh        # 首次为指定域名申请证书
    └── ensure-ssl-params.sh # 生成 ssl-dhparams.pem（若缺失）
```

- **conf.d**：仅包含 `*.conf`，便于 `include /etc/nginx/conf.d/*.conf` 行为一致。  
- **certbot/conf**：`live/`、`archive/` 由 certbot 生成，可不提交；`ssl-dhparams.pem` 可脚本生成后提交或加入 .gitignore 由每环境生成。  
- **options-ssl-nginx.conf**：来自 Certbot 官方推荐，放在 `nginx/ssl/` 并挂载到 `/etc/letsencrypt/`，由 Git 管理。

---

## 五、安全与运维建议

- **Staging 与限速**：首次接入新域名时可用 `--staging` 避免触发 Let's Encrypt 限频；确认无误后再用正式环境申请。  
- **密钥与权限**：`certbot/conf` 含私钥，需严格权限与备份策略；生产环境避免将 `certbot/conf` 整目录提交到公开仓库。  
- **资源限制**：在 `docker-compose` 中为 nginx/certbot 设置 `deploy.resources.limits`，防止单容器占满资源。  
- **健康检查**：nginx 使用 `GET /` 或自定义 `healthz`；certbot 可用 `certbot certificates` 或仅保证进程存在。  
- **日志**：统一 access/error 日志格式与路径，便于集中采集与审计。

---

## 六、总结

通过上述设计，本项目可成为：

- **多站点**：通过 conf.d 与统一命名规范扩展。  
- **GitOps 化**：配置与 SSL 选项进 Git，变更可追溯、可回滚。  
- **企业友好**：证书申请/续期脚本化、续期与重载联动、健康检查与资源限制、文档与流程明确。

后续实现将按本文档落实脚本、compose、README 与命名统一。
