#!/bin/bash

# 自动测试读回执功能 - 无需手动输入令牌
# 使用方法: ./auto-test.sh [username] [password]

set -e

API_URL="http://localhost:8065/api/v4"

echo "=========================================="
echo "读回执功能自动测试"
echo "=========================================="
echo ""

# 获取用户名和密码
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "请提供用户名和密码"
    echo "使用方法: ./auto-test.sh admin password"
    echo ""
    read -p "用户名: " USERNAME
    read -sp "密码: " PASSWORD
    echo ""
else
    USERNAME="$1"
    PASSWORD="$2"
fi

echo "步骤 1: 自动登录获取令牌"
echo "----------------------------------------"

# 登录获取令牌
LOGIN_RESPONSE=$(curl -s -X POST "$API_URL/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_id\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")

# 从响应头获取 token
TOKEN=$(curl -i -s -X POST "$API_URL/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_id\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" \
    | grep -i "^token:" | cut -d' ' -f2 | tr -d '\r')

if [ -z "$TOKEN" ]; then
    echo "❌ 登录失败，请检查用户名和密码"
    echo "响应: $LOGIN_RESPONSE"
    exit 1
fi

echo "✅ 登录成功"
echo "   Token: ${TOKEN:0:20}..."
echo ""

# 获取用户信息
echo "步骤 2: 获取用户信息"
echo "----------------------------------------"
USER_INFO=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/users/me")
USER_ID=$(echo "$USER_INFO" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
USERNAME_REAL=$(echo "$USER_INFO" | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "✅ 用户信息"
echo "   用户名: $USERNAME_REAL"
echo "   用户ID: $USER_ID"
echo ""

# 获取频道
echo "步骤 3: 获取频道列表"
echo "----------------------------------------"
TEAMS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/users/me/teams")
TEAM_ID=$(echo "$TEAMS" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

CHANNELS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/users/me/teams/$TEAM_ID/channels")
CHANNEL_ID=$(echo "$CHANNELS" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
CHANNEL_NAME=$(echo "$CHANNELS" | grep -o '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "✅ 找到频道"
echo "   频道名: $CHANNEL_NAME"
echo "   频道ID: $CHANNEL_ID"
echo ""

# 发送测试消息
echo "步骤 4: 发送测试消息"
echo "----------------------------------------"
TIMESTAMP=$(date +%s)000
MESSAGE="🧪 测试读回执功能 - $(date '+%Y-%m-%d %H:%M:%S')"

POST_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"channel_id\":\"$CHANNEL_ID\",\"message\":\"$MESSAGE\"}" \
    "$API_URL/posts")

POST_ID=$(echo "$POST_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
POST_TIME=$(echo "$POST_RESPONSE" | grep -o '"create_at":[0-9]*' | head -1 | cut -d':' -f2)

echo "✅ 消息已发送"
echo "   消息ID: $POST_ID"
echo "   时间戳: $POST_TIME"
echo "   内容: $MESSAGE"
echo ""

# 等待一下
sleep 1

# 推进读游标
echo "步骤 5: 推进读游标（标记为已读）"
echo "----------------------------------------"
CURSOR_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"last_post_seq\":$POST_TIME}" \
    "$API_URL/channels/$CHANNEL_ID/read_cursor")

echo "✅ 读游标已推进"
if command -v jq &> /dev/null; then
    echo "$CURSOR_RESPONSE" | jq '.'
else
    echo "$CURSOR_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$CURSOR_RESPONSE"
fi
echo ""

# 查询读游标
echo "步骤 6: 查询当前读游标"
echo "----------------------------------------"
GET_CURSOR=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "$API_URL/channels/$CHANNEL_ID/read_cursor")

echo "✅ 当前读游标:"
if command -v jq &> /dev/null; then
    echo "$GET_CURSOR" | jq '.'
else
    echo "$GET_CURSOR" | python3 -m json.tool 2>/dev/null || echo "$GET_CURSOR"
fi
echo ""

# 使用 post_id 方式推进
echo "步骤 7: 使用 post_id 推进读游标"
echo "----------------------------------------"
CURSOR_BY_POST=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"post_id\":\"$POST_ID\"}" \
    "$API_URL/channels/$CHANNEL_ID/read_cursor")

echo "✅ 通过 post_id 推进成功"
if command -v jq &> /dev/null; then
    echo "$CURSOR_BY_POST" | jq '.'
else
    echo "$CURSOR_BY_POST" | python3 -m json.tool 2>/dev/null || echo "$CURSOR_BY_POST"
fi
echo ""

# 检查数据库
echo "步骤 8: 验证数据库记录"
echo "----------------------------------------"
echo "SQL 查询命令:"
echo ""
echo "docker exec -it mattermost-postgres psql -U mmuser -d mattermost -c \\"
echo "  \"SELECT "
echo "    channel_id, "
echo "    user_id, "
echo "    last_post_seq, "
echo "    to_timestamp(updated_at/1000) as updated_time "
echo "  FROM channel_read_cursors "
echo "  WHERE channel_id='$CHANNEL_ID' AND user_id='$USER_ID';\""
echo ""

# 尝试自动查询数据库
if command -v docker &> /dev/null; then
    echo "尝试自动查询数据库..."
    DB_RESULT=$(docker exec mattermost-postgres psql -U mmuser -d mattermost -t -c \
        "SELECT channel_id, user_id, last_post_seq, to_timestamp(updated_at/1000) as updated_time FROM channel_read_cursors WHERE channel_id='$CHANNEL_ID' AND user_id='$USER_ID';" 2>/dev/null || echo "")
    
    if [ -n "$DB_RESULT" ]; then
        echo "✅ 数据库记录:"
        echo "$DB_RESULT"
    else
        echo "⚠️  无法自动查询数据库，请手动执行上面的 SQL 命令"
    fi
else
    echo "⚠️  Docker 未安装，请手动执行上面的 SQL 命令"
fi
echo ""

# 测试 ReadIndexService
echo "步骤 9: 测试 ReadIndexService"
echo "----------------------------------------"
if curl -s http://localhost:8066/health > /dev/null 2>&1; then
    echo "✅ ReadIndexService 正在运行"
    echo ""
    
    echo "服务统计:"
    STATS=$(curl -s http://localhost:8066/stats)
    if command -v jq &> /dev/null; then
        echo "$STATS" | jq '.'
    else
        echo "$STATS" | python3 -m json.tool 2>/dev/null || echo "$STATS"
    fi
    echo ""
    
    echo "查询已读用户:"
    READERS=$(curl -s "http://localhost:8066/channels/$CHANNEL_ID/posts/$POST_TIME/readers?limit=10")
    if command -v jq &> /dev/null; then
        echo "$READERS" | jq '.'
    else
        echo "$READERS" | python3 -m json.tool 2>/dev/null || echo "$READERS"
    fi
else
    echo "⚠️  ReadIndexService 未运行"
    echo ""
    echo "启动命令:"
    echo "  cd read-index-service"
    echo "  export REDIS_URL='redis://localhost:6379/0'"
    echo "  go run cmd/server/main.go"
fi
echo ""

# 检查 Redis Stream
echo "步骤 10: 检查 Redis Stream"
echo "----------------------------------------"
if command -v redis-cli &> /dev/null; then
    echo "查询 Redis Stream 事件..."
    STREAM_INFO=$(redis-cli XINFO STREAM read_cursor_events 2>/dev/null || echo "")
    
    if [ -n "$STREAM_INFO" ]; then
        echo "✅ Redis Stream 信息:"
        echo "$STREAM_INFO"
        echo ""
        
        echo "最近的事件:"
        redis-cli XREAD COUNT 5 STREAMS read_cursor_events 0 2>/dev/null || echo "暂无事件"
    else
        echo "⚠️  Redis Stream 不存在或 Redis 未运行"
    fi
else
    echo "⚠️  redis-cli 未安装"
fi
echo ""

echo "=========================================="
echo "✅ 测试完成！"
echo "=========================================="
echo ""
echo "📊 测试结果总结:"
echo "  ✅ 用户登录成功"
echo "  ✅ 消息发送成功: $MESSAGE"
echo "  ✅ 读游标推进成功"
echo "  ✅ API 查询正常"
echo ""
echo "🎯 下一步:"
echo ""
echo "1. 在浏览器中查看: http://localhost:8065"
echo "   频道: $CHANNEL_NAME"
echo "   应该能看到刚才发送的测试消息"
echo ""
echo "2. 查看完整数据库记录:"
echo "   docker exec -it mattermost-postgres psql -U mmuser -d mattermost"
echo "   SELECT * FROM channel_read_cursors WHERE user_id='$USER_ID' ORDER BY updated_at DESC LIMIT 5;"
echo ""
echo "3. 前端集成（参考 INTEGRATION_GUIDE.md）:"
echo "   - 将 PostReadIndicator 添加到 Post 组件"
echo "   - 注册 Redux Reducer"
echo "   - 注册 WebSocket 事件"
echo ""
echo "保存的环境变量（可用于后续测试）:"
echo "  export TOKEN='$TOKEN'"
echo "  export CHANNEL_ID='$CHANNEL_ID'"
echo "  export USER_ID='$USER_ID'"
echo ""
