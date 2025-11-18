#!/bin/bash

# Mattermost 服务器部署脚本
# 用途: 从 GitHub 拉取代码到远程服务器并启动 HA 集群
# 仓库: https://github.com/AvatoLabs/mattermost

set -e  # 遇到错误立即退出

# 配置
SERVER_IP="8.218.215.103"
SERVER_USER="root"
SERVER_PATH="/opt/mattermost"
GIT_REPO="https://github.com/AvatoLabs/mattermost.git"
GIT_BRANCH="master"  # 可以修改为其他分支

echo "=========================================="
echo "Mattermost 服务器部署脚本"
echo "=========================================="
echo ""

# 1. 从 GitHub 克隆或更新代码
echo "📦 步骤 1/4: 从 GitHub 拉取代码..."
ssh ${SERVER_USER}@${SERVER_IP} << EOF
# 检查目录是否存在
if [ -d "${SERVER_PATH}/.git" ]; then
  echo "代码仓库已存在，执行 git pull 更新..."
  cd ${SERVER_PATH}
  git fetch origin
  git reset --hard origin/${GIT_BRANCH}
  git clean -fdx
  echo "✅ 代码已更新到最新版本"
else
  echo "首次部署，克隆代码仓库..."
  rm -rf ${SERVER_PATH}
  git clone ${GIT_REPO} ${SERVER_PATH}
  cd ${SERVER_PATH}
  git checkout ${GIT_BRANCH}
  echo "✅ 代码已克隆"
fi

# 显示当前版本信息
echo ""
echo "� 当前代码版本:"
cd ${SERVER_PATH}
git log -1 --oneline
git status --short
EOF

# 2. 设置 go.work 文件
echo ""
echo "🔨 步骤 2/4: 设置 Go workspace..."
ssh ${SERVER_USER}@${SERVER_IP} << 'EOF'
cd /opt/mattermost/server

# 强制重新创建 go.work 文件以确保路径正确
echo "重新创建 go.work 文件..."
rm -f go.work go.work.sum
go work init
go work use .
go work use ./public
go work use ../enterprise
echo "✅ go.work 文件已创建"

# 验证 go.work 内容
echo ""
echo "📄 go.work 文件内容:"
cat go.work

# 清理 Go 模块缓存并下载依赖
echo ""
echo "📥 预下载 Go 依赖..."
cd /opt/mattermost/server
go mod download
cd /opt/mattermost/enterprise
go mod download
cd /opt/mattermost/server/public
go mod download
echo "✅ Go 依赖已下载"
EOF

# 3. 停止现有容器并清理
echo ""
echo "🛑 步骤 3/4: 停止现有容器并清理..."
ssh ${SERVER_USER}@${SERVER_IP} << 'EOF'
cd /opt/mattermost/server
docker compose down

# 清理旧的构建镜像以避免缓存问题
echo "清理旧的 Docker 镜像..."
docker rmi -f server-leader server-follower server-follower2 2>/dev/null || true
echo "✅ 容器已停止，镜像已清理"
EOF

# 4. 启动服务
echo ""
echo "🚀 步骤 4/4: 启动 Mattermost HA 集群..."
ssh ${SERVER_USER}@${SERVER_IP} << 'EOF'
cd /opt/mattermost/server

# 设置 CURRENT_UID 环境变量
export CURRENT_UID=$(id -u):$(id -g)

# 启动服务
echo "启动 docker compose..."
docker compose up -d

echo ""
echo "等待 10 秒让服务启动..."
sleep 10

echo ""
echo "📊 容器状态:"
docker compose ps

echo ""
echo "📝 查看 leader 容器日志 (最后 20 行):"
docker logs server-leader-1 --tail 20 2>&1 || echo "leader 容器尚未创建"
EOF

echo ""
echo "=========================================="
echo "✅ 部署完成!"
echo "=========================================="
echo ""
echo "访问地址: http://${SERVER_IP}:8065"
echo ""
echo "常用命令:"
echo "  查看日志: ssh ${SERVER_USER}@${SERVER_IP} 'cd ${SERVER_PATH}/server && docker compose logs -f'"
echo "  查看状态: ssh ${SERVER_USER}@${SERVER_IP} 'cd ${SERVER_PATH}/server && docker compose ps'"
echo "  重启服务: ssh ${SERVER_USER}@${SERVER_IP} 'cd ${SERVER_PATH}/server && docker compose restart'"
echo "  停止服务: ssh ${SERVER_USER}@${SERVER_IP} 'cd ${SERVER_PATH}/server && docker compose down'"
echo ""
