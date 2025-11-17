#!/bin/bash

# Mattermost 读回执功能测试脚本
# 使用方法: ./test-read-receipts.sh

set -e

# 配置
MATTERMOST_URL="${MATTERMOST_URL:-http://localhost:8065}"
API_URL="$MATTERMOST_URL/api/v4"

echo "=========================================="
echo "Mattermost 读回执功能测试"
echo "=========================================="
echo ""

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查是否提供了 token
if [ -z "$MATTERMOST_TOKEN" ]; then
    echo -e "${RED}错误: 请设置 MATTERMOST_TOKEN 环境变量${NC}"
    echo "获取方法: 登录 Mattermost -> 个人设置 -> 安全 -> 个人访问令牌"
    echo ""
    echo "使用方法:"
    echo "  export MATTERMOST_TOKEN='your-token-here'"
    echo "  ./test-read-receipts.sh"
    exit 1
fi

# 检查是否提供了 channel_id
if [ -z "$TEST_CHANNEL_ID" ]; then
    echo -e "${YELLOW}提示: 未设置 TEST_CHANNEL_ID，将尝试获取第一个频道${NC}"
    echo ""
fi

AUTH_HEADER="Authorization: Bearer $MATTERMOST_TOKEN"

echo "1. 测试 Server 连接..."
response=$(curl -s -w "\n%{http_code}" -H "$AUTH_HEADER" "$API_URL/users/me")
http_code=$(echo "$response" | tail -n1)
if [ "$http_code" = "200" ]; then
    echo -e "${GREEN}✓ Server 连接成功${NC}"
    user_id=$(echo "$response" | head -n-1 | jq -r '.id')
    echo "  用户 ID: $user_id"
else
    echo -e "${RED}✗ Server 连接失败 (HTTP $http_code)${NC}"
    exit 1
fi
echo ""

# 获取频道 ID（如果未提供）
if [ -z "$TEST_CHANNEL_ID" ]; then
    echo "2. 获取测试频道..."
    response=$(curl -s -w "\n%{http_code}" -H "$AUTH_HEADER" "$API_URL/users/me/teams")
    http_code=$(echo "$response" | tail -n1)
    if [ "$http_code" = "200" ]; then
        team_id=$(echo "$response" | head -n-1 | jq -r '.[0].id')
        echo "  团队 ID: $team_id"
        
        # 获取频道列表
        response=$(curl -s -w "\n%{http_code}" -H "$AUTH_HEADER" "$API_URL/users/me/teams/$team_id/channels")
        http_code=$(echo "$response" | tail -n1)
        if [ "$http_code" = "200" ]; then
            TEST_CHANNEL_ID=$(echo "$response" | head -n-1 | jq -r '.[0].id')
            channel_name=$(echo "$response" | head -n-1 | jq -r '.[0].display_name')
            echo -e "${GREEN}✓ 找到测试频道: $channel_name${NC}"
            echo "  频道 ID: $TEST_CHANNEL_ID"
        fi
    fi
fi
echo ""

if [ -z "$TEST_CHANNEL_ID" ]; then
    echo -e "${RED}错误: 无法获取测试频道${NC}"
    echo "请手动设置: export TEST_CHANNEL_ID='your-channel-id'"
    exit 1
fi

echo "3. 测试推进读游标 API..."
current_time=$(date +%s)000  # 毫秒时间戳
payload=$(cat <<EOF
{
    "last_post_seq": $current_time
}
EOF
)

response=$(curl -s -w "\n%{http_code}" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "$API_URL/channels/$TEST_CHANNEL_ID/read_cursor")

http_code=$(echo "$response" | tail -n1)
if [ "$http_code" = "200" ]; then
    echo -e "${GREEN}✓ 推进读游标成功${NC}"
    echo "$response" | head -n-1 | jq '.'
else
    echo -e "${RED}✗ 推进读游标失败 (HTTP $http_code)${NC}"
    echo "$response" | head -n-1
fi
echo ""

echo "4. 测试获取读游标 API..."
response=$(curl -s -w "\n%{http_code}" \
    -H "$AUTH_HEADER" \
    "$API_URL/channels/$TEST_CHANNEL_ID/read_cursor")

http_code=$(echo "$response" | tail -n1)
if [ "$http_code" = "200" ]; then
    echo -e "${GREEN}✓ 获取读游标成功${NC}"
    echo "$response" | head -n-1 | jq '.'
elif [ "$http_code" = "404" ]; then
    echo -e "${YELLOW}⚠ 该频道暂无读游标记录${NC}"
else
    echo -e "${RED}✗ 获取读游标失败 (HTTP $http_code)${NC}"
    echo "$response" | head -n-1
fi
echo ""

echo "5. 检查数据库记录..."
echo -e "${YELLOW}提示: 需要直接访问数据库来验证${NC}"
echo "SQL 查询:"
echo "  SELECT * FROM channel_read_cursors WHERE channel_id = '$TEST_CHANNEL_ID' AND user_id = '$user_id';"
echo ""

echo "=========================================="
echo "测试完成！"
echo "=========================================="
echo ""
echo "后续步骤:"
echo "1. 启动 ReadIndexService (可选):"
echo "   cd read-index-service && go run cmd/server/main.go"
echo ""
echo "2. 测试 ReadIndexService API (如果已启动):"
echo "   curl http://localhost:8066/health"
echo "   curl http://localhost:8066/stats"
echo ""
echo "3. 实现前端 UI 组件"
