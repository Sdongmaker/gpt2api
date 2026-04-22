# gpt2api 部署

当前仓库保留的是一套“远端服务器拉镜像部署”方案:

- `deploy/docker-compose.yml`:当前唯一的部署编排
- `deploy/.env.example`:当前唯一的环境变量模板
- `deploy/remote-deploy.sh`:目标服务器执行的更新脚本

这套方案只部署 `server` 服务:

- MySQL / Redis 需要你提前准备好
- 推荐和 `gpt2api-server` 一起挂到 `1panel-network`
- 入口端口默认只绑定到 `127.0.0.1:${HTTP_PORT}`

## 快速开始

```bash
cd deploy
cp .env.example .env
```

至少修改这些配置:

- `DOCKERHUB_IMAGE`
- `MYSQL_HOST` / `MYSQL_PORT` / `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_DATABASE`
- `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / `REDIS_DB`
- `JWT_SECRET`
- `CRYPTO_AES_KEY`

启动:

```bash
docker compose up -d
docker compose logs -f server
```

## 数据与日志

- `backups`:`/app/data/backups` —— 数据库备份文件(.sql.gz)落盘目录
- `./logs`:宿主机 `deploy/logs` —— server 日志

## 安全红线

以下必须在 **.env** 中显式覆盖(生产禁用默认值):

- `JWT_SECRET`:至少 32 字符随机串
- `CRYPTO_AES_KEY`:**严格** 64 位 hex(32 字节 AES-256 key)
- `MYSQL_PASSWORD`
- `REDIS_PASSWORD`

## GitHub Actions 自动构建镜像 + 推送 Docker Hub + 远端自动更新

仓库里当前这套发布链路由以下文件组成:

- 工作流文件:`.github/workflows/docker-release.yml`
- 部署编排:`deploy/docker-compose.yml`
- 远端更新脚本:`deploy/remote-deploy.sh`
- 服务器环境变量模板:`deploy/.env.example`

### 方案说明

当前项目的 `deploy/Dockerfile` 不是在容器里现编译代码,而是依赖以下预构建产物:

- `deploy/bin/gpt2api`
- `deploy/bin/goose`
- `web/dist/`

所以工作流会先在 GitHub Runner 里执行 `bash deploy/build-local.sh --force`,再进行 `docker build` 和 `docker push`。发布成功后,再通过 SSH 登录目标服务器,同步远端部署文件并执行:

```bash
docker compose -f docker-compose.yml pull server
docker compose -f docker-compose.yml up -d --remove-orphans
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
scp deploy/.env.example <user>@<host>:/opt/gpt2api/.env.example
scp configs/config.example.yaml <user>@<host>:/opt/gpt2api/configs/config.example.yaml
```

再基于模板生成正式配置:

```bash
cp .env.example .env
cp configs/config.example.yaml configs/config.yaml
```

然后至少完成两件事:

1. 修改 `.env` 中的 `DOCKERHUB_IMAGE`、`MYSQL_*`、`REDIS_*`、`JWT_SECRET`、`CRYPTO_AES_KEY`
2. 修改 `configs/config.yaml` 中真正的业务配置

注意:

- 远端部署不会覆盖你服务器上的 `.env` 和 `configs/config.yaml`
- 这两个文件是运行必需项,缺失时 `remote-deploy.sh` 会直接失败
- 当前工作流构建的是 `linux/amd64` 镜像,目标服务器也需要是 `amd64/x86_64`
- 当前远端 compose 只部署 `server` 服务,MySQL / Redis 需要提前准备好
- 如果你在 1Panel 上部署,当前模板默认使用 `1panel-network`,并把 `server` 端口绑定到 `127.0.0.1`

### 1Panel 部署说明

`deploy/.env.example` 已经按 1Panel 场景给了默认值:

- `APP_NETWORK_NAME=1panel-network`
- `APP_NETWORK_EXTERNAL=true`
- `HTTP_BIND_HOST=127.0.0.1`
- `MYSQL_HOST=mysql`
- `REDIS_HOST=redis`
- `REDIS_PASSWORD=please_change_me`

这样远端 compose 会:

- 直接加入 1Panel 自带的 `1panel-network`
- 只启动 `gpt2api-server`
- 把端口映射成 `127.0.0.1:宿主端口:容器端口`
- 通过 `.env` 中的 `MYSQL_HOST` / `REDIS_HOST` 去连接你已经存在的数据库和缓存

例如 server 实际会映射成:

```bash
127.0.0.1:${HTTP_PORT}:8080
```

在 1Panel 站点反代里,上游地址直接填:

```text
127.0.0.1:${HTTP_PORT}
```

如果你的 MySQL / Redis 也是跑在 1Panel 容器里,推荐把 `MYSQL_HOST` / `REDIS_HOST` 配成它们在 `1panel-network` 里的容器名或服务名,不要填 `127.0.0.1`。

原因是:

- 容器内的 `127.0.0.1` 指向的是 `gpt2api-server` 自己
- 只有数据库/缓存和 `gpt2api-server` 在同一个 Docker 网络里,才能通过容器名互相访问

如果 Redis 开了密码,把 `.env` 里的 `REDIS_PASSWORD` 改成真实值即可;工作流同步后的 compose 会自动注入 `GPT2API_REDIS_PASSWORD`。

如果你不是跑在 1Panel 上,把这两项改掉即可:

```env
APP_NETWORK_NAME=gpt2api-network
APP_NETWORK_EXTERNAL=false
```

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

- `/opt/gpt2api/docker-compose.yml`
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
