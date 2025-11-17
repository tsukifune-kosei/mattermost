#!/bin/bash

# 多用户读回执测试脚本
# 模拟多个用户阅读同一条消息

set -e

BASE_URL="http://localhost:8065"
API_URL="$BASE_URL/api/v4"

echo "=========================================="
echo "多用户读回执测试"
echo "=========================================="

# 创建测试用户函数
create_user() {
    local username=$1
    local email=$2
    local password=$3
    
    curl -s -X POST "$API_URL/users" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"$username\",
            \"email\": \"$email\",
            \"password\": \"$password\"
        }" | jq -r '.id'
}

# 登录函数
login_user() {
    local username=$1
    local password=$2
    
    curl -s -X POST "$API_URL/users/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"login_id\": \"$username\",
            \"password\": \"$password\"
        }" -i | grep -i "^token:" | awk '{print $2}' | tr -d '\r'
}

# 推进读游标
advance_cursor() {
    local token=$1
    local channel_id=$2
    local seq=$3
    
    curl -s -X POST "$API_URL/channels/$channel_id/read_cursor/advance" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"last_post_seq\": $seq}"
}

echo ""
echo "1. 使用管理员账号登录..."
ADMIN_TOKEN=$(login_user "arthur" "the17thangel")
if [ -z "$ADMIN_TOKEN" ]; then
    echo "❌ 管理员登录失败"
    exit 1
fi
echo "✅ 管理员登录成功"

# 获取团队和频道
echo ""
echo "2. 获取团队和频道信息..."
TEAM_ID=$(curl -s -X GET "$API_URL/users/me/teams" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')
CHANNEL_ID=$(curl -s -X GET "$API_URL/teams/$TEAM_ID/channels" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[] | select(.name=="town-square") | .id')

echo "✅ 团队ID: $TEAM_ID"
echo "✅ 频道ID: $CHANNEL_ID"

# 发送一条测试消息
echo ""
echo "3. 发送测试消息..."
MESSAGE_RESPONSE=$(curl -s -X POST "$API_URL/posts" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"channel_id\": \"$CHANNEL_ID\",
        \"message\": \"📨 测试消息 - 多用户读回执测试 $(date)\"
    }")

MESSAGE_ID=$(echo $MESSAGE_RESPONSE | jq -r '.id')
MESSAGE_SEQ=$(echo $MESSAGE_RESPONSE | jq -r '.create_at')

echo "✅ 消息ID: $MESSAGE_ID"
echo "✅ 消息序列号: $MESSAGE_SEQ"

# 创建3个测试用户
echo ""
echo "4. 创建测试用户..."
TIMESTAMP=$(date +%s)

USER1_ID=$(create_user "testuser1_$TIMESTAMP" "testuser1_$TIMESTAMP@example.com" "Password123!")
USER2_ID=$(create_user "testuser2_$TIMESTAMP" "testuser2_$TIMESTAMP@example.com" "Password123!")
USER3_ID=$(create_user "testuser3_$TIMESTAMP" "testuser3_$TIMESTAMP@example.com" "Password123!")

echo "✅ 用户1 ID: $USER1_ID"
echo "✅ 用户2 ID: $USER2_ID"
echo "✅ 用户3 ID: $USER3_ID"

# 将用户添加到团队和频道
echo ""
echo "5. 添加用户到团队和频道..."
for USER_ID in $USER1_ID $USER2_ID $USER3_ID; do
    # 添加到团队
    curl -s -X POST "$API_URL/teams/$TEAM_ID/members" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"team_id\": \"$TEAM_ID\", \"user_id\": \"$USER_ID\"}" > /dev/null
    
    # 添加到频道
    curl -s -X POST "$API_URL/channels/$CHANNEL_ID/members" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"user_id\": \"$USER_ID\"}" > /dev/null
done
echo "✅ 所有用户已添加到频道"

# 登录各个用户并推进读游标
echo ""
echo "6. 模拟用户阅读消息..."

echo "  📖 用户1 阅读消息..."
USER1_TOKEN=$(login_user "testuser1_$TIMESTAMP" "Password123!")
RESULT1=$(advance_cursor "$USER1_TOKEN" "$CHANNEL_ID" "$MESSAGE_SEQ")
echo "  Response: $RESULT1"
echo "  ✅ 用户1 已读"

sleep 1

echo "  📖 用户2 阅读消息..."
USER2_TOKEN=$(login_user "testuser2_$TIMESTAMP" "Password123!")
RESULT2=$(advance_cursor "$USER2_TOKEN" "$CHANNEL_ID" "$MESSAGE_SEQ")
echo "  Response: $RESULT2"
echo "  ✅ 用户2 已读"

sleep 1

echo "  📖 用户3 阅读消息..."
USER3_TOKEN=$(login_user "testuser3_$TIMESTAMP" "Password123!")
RESULT3=$(advance_cursor "$USER3_TOKEN" "$CHANNEL_ID" "$MESSAGE_SEQ")
echo "  Response: $RESULT3"
echo "  ✅ 用户3 已读"

# 查询读回执统计
echo ""
echo "7. 查询读回执统计..."
READ_COUNT=$(curl -s -X GET "$API_URL/posts/$MESSAGE_ID/read_receipts/count" \
    -H "Authorization: Bearer $ADMIN_TOKEN")

echo "✅ 读回执统计: $READ_COUNT"

# 查询详细读回执列表
echo ""
echo "8. 查询详细读回执列表..."
READ_RECEIPTS=$(curl -s -X GET "$API_URL/posts/$MESSAGE_ID/read_receipts" \
    -H "Authorization: Bearer $ADMIN_TOKEN")

echo "✅ 读回执详情:"
echo "$READ_RECEIPTS" | jq '.'

# 验证数据库
echo ""
echo "9. 验证数据库记录..."
docker exec mattermost-postgres psql -U mmuser -d mattermost_test -c \
    "SELECT channel_id, user_id, last_post_seq FROM channel_read_cursors WHERE channel_id = '$CHANNEL_ID' ORDER BY updated_at DESC LIMIT 5;"

echo ""
echo "=========================================="
echo "✅ 多用户测试完成！"
echo "=========================================="
echo ""
echo "测试结果："
echo "  - 消息ID: $MESSAGE_ID"
echo "  - 消息序列号: $MESSAGE_SEQ"
echo "  - 频道ID: $CHANNEL_ID"
echo "  - 已读用户数: 3"
echo ""
echo "现在刷新浏览器，你应该能看到这条消息显示 '3 read'！"
echo ""
echo "测试用户账号（可用于登录验证）："
echo "  - testuser1_$TIMESTAMP / Password123!"
echo "  - testuser2_$TIMESTAMP / Password123!"
echo "  - testuser3_$TIMESTAMP / Password123!"
