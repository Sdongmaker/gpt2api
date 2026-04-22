# gpt2api 容器化部署

一键启动 = `docker compose up -d`。Server 启动时自动:

1. 等 MySQL 健康
2. 跑 `goose up` 应用所有迁移(包含用户表、账号池、审计、备份元数据等)
3. 启动 HTTP 服务(`:8080`)

## 快速开始

```bash
cd deploy
cp .env.example .env           # 修改 JWT_SECRET / CRYPTO_AES_KEY / MySQL 密码
docker compose up -d --build
docker compose logs -f server  # 观察迁移 + 启动日志
```

默认暴露端口:


| 服务     | 端口     | 说明                   |
| ------ | ------ | -------------------- |
| server | `8080` | OpenAI 兼容网关 + 后台 API |
| mysql  | `3306` | 业务数据库                |
| redis  | `6379` | 锁 / 限流 / 缓存          |


## 目录与数据卷

- `mysql_data`:MySQL 物理数据
- `redis_data`:Redis AOF
- `backups`:`/app/data/backups` —— 数据库备份文件(.sql.gz)落盘目录
- `./logs`:宿主机 `deploy/logs` —— server 日志

数据库备份和宿主机数据是两条独立路径:

- 管理员在后台"数据备份"里点"立即备份"会把 `mysqldump` 压缩写入 `backups` 卷;
- `backups` 卷也可以挂回宿主机目录来做 rsync 异地冷备。

## 安全红线

以下必须在 **.env** 中显式覆盖(生产禁用默认值):

- `JWT_SECRET`:至少 32 字符随机串
- `CRYPTO_AES_KEY`:**严格** 64 位 hex(32 字节 AES-256 key)
- `MYSQL_ROOT_PASSWORD` / `MYSQL_PASSWORD`

后端对高危操作的保护:


| 操作        | 权限常量            | 额外要求                                                     |
| --------- | --------------- | -------------------------------------------------------- |
| 列出/下载备份   | `system:backup` | -                                                        |
| 创建备份      | `system:backup` | -                                                        |
| 删除备份      | `system:backup` | `X-Admin-Confirm: <password>`                            |
| 上传备份      | `system:backup` | `X-Admin-Confirm: <password>`                            |
| **恢复数据库** | `system:backup` | `backup.allow_restore=true`(默认 false)+ `X-Admin-Confirm` |
| 调整用户积分    | `user:credit`   | 自动落审计                                                    |


凡是 `/api/admin/`* 的写操作(POST/PUT/PATCH/DELETE)都会被 `audit.Middleware` 自动记录到 `admin_audit_logs` 表,管理员可在"审计日志"页查看。

## 恢复数据库的标准流程

因为 `restore` 会直接覆盖现库,**默认关闭**。启用方式:

1. 在 `.env` 中 `BACKUP_ALLOW_RESTORE=true`
2. `docker compose up -d server`(重启生效)
3. 在后台点"恢复",输入管理员密码二次确认
4. 完成后把 `.env` 改回 `false` 再重启,锁回常态

## 常用运维命令

```bash
# 手动触发一次迁移(平时容器启动时会自动跑)
docker compose exec server goose -dir /app/sql/migrations mysql \
  "$GPT2API_MYSQL_DSN" up

# 查看当前迁移状态
docker compose exec server goose -dir /app/sql/migrations mysql \
  "$GPT2API_MYSQL_DSN" status

# 进入 MySQL
docker compose exec mysql mysql -ugpt2api -p gpt2api

# 冷备份(API 之外的兜底方式)
docker compose exec server mysqldump -hmysql -ugpt2api -p \
  --single-transaction --quick gpt2api | gzip > gpt2api-$(date +%F).sql.gz
```

## 单节点 vs 多节点

当前 compose 配置针对单机部署。后续要做多副本:

- `server` 可直接 `docker compose up -d --scale server=3`(需前面加 nginx/traefik)
- `backups` 卷改成共享存储(NFS / S3 fuse),否则每个副本只能看到自己创建的备份
- Redis 分布式锁已天然支持多副本,MySQL 和 JWT 密钥需统一

## GitHub Actions 自动构建镜像 + 推送 Docker Hub + 远端自动更新

仓库已经补了一套可直接落地的发布链路:

- 工作流文件:`.github/workflows/docker-release.yml`
- 远端专用编排:`deploy/docker-compose.remote.yml`
- 远端更新脚本:`deploy/remote-deploy.sh`
- 服务器环境变量模板:`deploy/.env.remote.example`

### 方案说明

当前项目的 `deploy/Dockerfile` 不是在容器里现编译代码,而是依赖以下预构建产物:

- `deploy/bin/gpt2api`
- `deploy/bin/goose`
- `web/dist/`

所以工作流会先在 GitHub Runner 里执行 `bash deploy/build-local.sh --force`,再进行 `docker build` 和 `docker push`。发布成功后,再通过 SSH 登录目标服务器,同步远端部署文件并执行:

```bash
docker compose -f docker-compose.remote.yml pull server
docker compose -f docker-compose.remote.yml up -d --remove-orphans
```

### 触发规则

- `push` 到 `main` 时自动构建、推送、部署
- 手动触发 `workflow_dispatch` 时会重新构建并推送镜像

镜像标签策略:

- 固定生成一个不可变标签:`sha-<7位提交号>`
- 同时更新 `latest`
- 远端部署默认使用这次构建对应的 `sha-*` 标签,避免“latest 被覆盖后版本不确定”

### 目标服务器首次准备

以下示例以 `/opt/gpt2api` 为部署目录:

```bash
sudo mkdir -p /opt/gpt2api/configs /opt/gpt2api/logs
sudo chown -R $USER:$USER /opt/gpt2api
cd /opt/gpt2api
```

首次启用工作流前,先把仓库里的模板文件手动放上服务器:

```bash
scp deploy/.env.remote.example <user>@<host>:/opt/gpt2api/.env.example
scp configs/config.example.yaml <user>@<host>:/opt/gpt2api/configs/config.example.yaml
```

再基于模板生成正式配置:

```bash
cp .env.example .env
cp configs/config.example.yaml configs/config.yaml
```

然后至少完成两件事:

1. 修改 `.env` 中的 `MYSQL_*`、`JWT_SECRET`、`CRYPTO_AES_KEY`
2. 修改 `configs/config.yaml` 中真正的业务配置

注意:

- 远端部署不会覆盖你服务器上的 `.env` 和 `configs/config.yaml`
- 这两个文件是运行必需项,缺失时 `remote-deploy.sh` 会直接失败
- 当前工作流构建的是 `linux/amd64` 镜像,目标服务器也需要是 `amd64/x86_64`

### GitHub 仓库 Variables

在仓库 `Settings -> Secrets and variables -> Actions -> Variables` 中添加:

- `DOCKERHUB_IMAGE`:Docker Hub 仓库名,例如 `yourname/gpt2api`
- `DEPLOY_HOST`:目标服务器 IP 或域名
- `DEPLOY_USER`:SSH 登录用户
- `DEPLOY_PORT`:可选,默认 `22`
- `DEPLOY_PATH`:可选,默认 `/opt/gpt2api`

### GitHub 仓库 Secrets

在同一页面添加:

- `DOCKERHUB_USERNAME`:Docker Hub 用户名
- `DOCKERHUB_TOKEN`:Docker Hub Access Token
- `DEPLOY_SSH_KEY`:用于登录目标服务器的私钥内容

工作流现在会在运行时自动执行 `ssh-keyscan -p <DEPLOY_PORT> -H <DEPLOY_HOST>` 生成 `known_hosts`,所以不再需要额外配置 `DEPLOY_KNOWN_HOSTS`。

### 远端目录结构

部署脚本会把以下文件同步到服务器:

- `/opt/gpt2api/docker-compose.remote.yml`
- `/opt/gpt2api/remote-deploy.sh`
- `/opt/gpt2api/.env.example`
- `/opt/gpt2api/configs/config.example.yaml`

你自己维护的文件:

- `/opt/gpt2api/.env`
- `/opt/gpt2api/configs/config.yaml`

### 私有镜像仓库说明

如果 Docker Hub 仓库是私有的,请先在目标服务器手动执行一次:

```bash
docker login
```

保证服务器有权限拉取目标镜像,否则远端 `docker compose pull server` 会失败。

### 手动复用同一套部署脚本

除了 GitHub Actions,你也可以在服务器上直接执行:

```bash
cd /opt/gpt2api
export DOCKERHUB_IMAGE=docker.io/yourname/gpt2api
export IMAGE_TAG=latest
./remote-deploy.sh
```

这在需要紧急回滚或手工切换镜像标签时会比较方便。
