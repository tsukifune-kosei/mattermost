#!/bin/bash

# 纯后端测试 - 不需要浏览器
# 使用方法: ./backend-test.sh username password

set -e

API_URL="http://localhost:8065/api/v4"
USERNAME="${1:-admin}"
PASSWORD="${2:-admin}"

echo "=========================================="
echo "后端功能测试（无需浏览器）"
echo "=========================================="
echo ""

# 1. 登录
echo "1. 登录..."
TOKEN=$(curl -i -s -X POST "$API_URL/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_id\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" \
    | grep -i "^token:" | cut -d' ' -f2 | tr -d '\r')

if [ -z "$TOKEN" ]; then
    echo "❌ 登录失败"
    exit 1
fi
echo "✅ 登录成功"

# 2. 获取用户信息
USER_INFO=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/users/me")
USER_ID=$(echo "$USER_INFO" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "✅ 用户ID: $USER_ID"

# 3. 创建测试团队（如果不存在）
echo ""
echo "2. 准备测试环境..."
TEAM_NAME="test-read-receipts-$(date +%s)"
TEAM_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"name\":\"$TEAM_NAME\",\"display_name\":\"测试读回执\",\"type\":\"O\"}" \
    "$API_URL/teams")
TEAM_ID=$(echo "$TEAM_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$TEAM_ID" ]; then
    # 如果创建失败，尝试获取现有团队
    TEAMS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/users/me/teams")
    TEAM_ID=$(echo "$TEAMS" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
fi

echo "✅ 团队ID: $TEAM_ID"

# 4. 创建测试频道
CHANNEL_NAME="test-channel-$(date +%s)"
CHANNEL_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"team_id\":\"$TEAM_ID\",\"name\":\"$CHANNEL_NAME\",\"display_name\":\"测试频道\",\"type\":\"O\"}" \
    "$API_URL/channels")
CHANNEL_ID=$(echo "$CHANNEL_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$CHANNEL_ID" ]; then
    # 如果创建失败，使用现有频道
    CHANNELS=$(curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/users/me/teams/$TEAM_ID/channels")
    CHANNEL_ID=$(echo "$CHANNELS" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
fi

echo "✅ 频道ID: $CHANNEL_ID"

# 5. 发送测试消息
echo ""
echo "3. 发送测试消息..."
for i in {1..3}; do
    POST_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"channel_id\":\"$CHANNEL_ID\",\"message\":\"测试消息 #$i - $(date '+%H:%M:%S')\"}" \
        "$API_URL/posts")
    POST_ID=$(echo "$POST_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    POST_TIME=$(echo "$POST_RESPONSE" | grep -o '"create_at":[0-9]*' | head -1 | cut -d':' -f2)
    echo "  ✅ 消息 #$i: $POST_ID (时间戳: $POST_TIME)"
    sleep 0.5
done

# 6. 推进读游标
echo ""
echo "4. 推进读游标..."
CURSOR_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"last_post_seq\":$POST_TIME}" \
    "$API_URL/channels/$CHANNEL_ID/read_cursor")

echo "✅ 读游标已推进到: $POST_TIME"
if command -v jq &> /dev/null; then
    echo "$CURSOR_RESPONSE" | jq '.'
else
    echo "$CURSOR_RESPONSE"
fi

# 7. 查询读游标
echo ""
echo "5. 查询读游标..."
GET_CURSOR=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "$API_URL/channels/$CHANNEL_ID/read_cursor")

if echo "$GET_CURSOR" | grep -q "error"; then
    echo "❌ 查询失败:"
    echo "$GET_CURSOR"
else
    echo "✅ 查询成功:"
    if command -v jq &> /dev/null; then
        echo "$GET_CURSOR" | jq '.'
    else
        echo "$GET_CURSOR"
    fi
fi

# 8. 验证数据库
echo ""
echo "6. 验证数据库..."
if command -v docker &> /dev/null; then
    DB_RESULT=$(docker exec -e PGPASSWORD=mostest mattermost-postgres psql -U mmuser -d mattermost_test -t -c \
        "SELECT COUNT(*) FROM channel_read_cursors WHERE channel_id='$CHANNEL_ID' AND user_id='$USER_ID';" 2>/dev/null || echo "0")
    
    if [ "$DB_RESULT" -gt 0 ]; then
        echo "✅ 数据库中有 $DB_RESULT 条记录"
        docker exec -e PGPASSWORD=mostest mattermost-postgres psql -U mmuser -d mattermost_test -c \
            "SELECT channel_id, user_id, last_post_seq, to_timestamp(updated_at/1000) as updated_time FROM channel_read_cursors WHERE channel_id='$CHANNEL_ID' AND user_id='$USER_ID';"
    else
        echo "⚠️  数据库中没有记录"
    fi
else
    echo "⚠️  Docker 未安装，跳过数据库验证"
fi

echo ""
echo "=========================================="
echo "✅ 后端测试完成！"
echo "=========================================="
echo ""
echo "测试结果:"
echo "  - 用户ID: $USER_ID"
echo "  - 频道ID: $CHANNEL_ID"
echo "  - 最后消息时间戳: $POST_TIME"
echo ""
echo "环境变量:"
echo "  export TOKEN='$TOKEN'"
echo "  export CHANNEL_ID='$CHANNEL_ID'"
echo "  export USER_ID='$USER_ID'"
echo ""
