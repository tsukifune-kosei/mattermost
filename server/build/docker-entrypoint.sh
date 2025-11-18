#!/bin/bash
set -e

# 确保 go.work 文件正确设置
if [ -f "/home/mattermost-server/server/Makefile" ]; then
    cd /home/mattermost-server/server
    
    # 强制设置环境变量
    export BUILD_ENTERPRISE_READY=true
    export BUILD_ENTERPRISE_DIR=../enterprise
    export BUILD_ENTERPRISE=true
    
    # 清理并重新创建 go.work
    rm -f go.work go.work.sum
    go work init
    go work use .
    go work use ./public
    
    # 检查 enterprise 目录是否存在
    if [ -d "../enterprise" ]; then
        echo "添加 enterprise 模块到 go workspace..."
        go work use ../enterprise
    else
        echo "警告: enterprise 目录不存在"
    fi
    
    # 显示 go.work 内容
    echo "go.work 文件内容:"
    cat go.work
fi

# 执行传入的命令
exec "$@"
