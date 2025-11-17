#!/bin/bash

# 快速测试读回执功能
# 使用方法: ./quick-test.sh

echo "=========================================="
echo "读回执功能快速测试"
echo "=========================================="
echo ""

# 1. 获取 Token
echo "步骤 1: 获取访问令牌"
echo "----------------------------------------"
echo "1. 打开浏览器访问: http://localhost:8065"
echo "2. 登录 Mattermost"
echo "3. 点击右上角头像 -> 个人设置"
echo "4. 安全 -> 个人访问令牌"
echo "5. 创建令牌并复制"
echo ""
read -p "请输入你的 Token: " TOKEN
echo ""

if [ -z "$TOKEN" ]; then
    echo "错误: Token 不能为空"
    exit 1
fi

# 2. 获取用户信息
echo "步骤 2: 获取用户信息"
echo "----------------------------------------"
USER_INFO=$(curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8065/api/v4/users/me)
USER_ID=$(echo $USER_INFO | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
USERNAME=$(echo $USER_INFO | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$USER_ID" ]; then
    echo "❌ 无法获取用户信息，请检查 Token 是否正确"
    exit 1
fi

echo "✅ 登录成功"
echo "   用户名: $USERNAME"
echo "   用户ID: $USER_ID"
echo ""

# 3. 获取频道列表
echo "步骤 3: 获取频道列表"
echo "----------------------------------------"
TEAMS=$(curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8065/api/v4/users/me/teams)
TEAM_ID=$(echo $TEAMS | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

CHANNELS=$(curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:8065/api/v4/users/me/teams/$TEAM_ID/channels")
CHANNEL_ID=$(echo $CHANNELS | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
CHANNEL_NAME=$(echo $CHANNELS | grep -o '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "✅ 找到频道"
echo "   频道名: $CHANNEL_NAME"
echo "   频道ID: $CHANNEL_ID"
echo ""

# 4. 发送一条测试消息
echo "步骤 4: 发送测试消息"
echo "----------------------------------------"
TIMESTAMP=$(date +%s)000
MESSAGE="测试读回执功能 - $TIMESTAMP"

POST_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"channel_id\":\"$CHANNEL_ID\",\"message\":\"$MESSAGE\"}" \
    http://localhost:8065/api/v4/posts)

POST_ID=$(echo $POST_RESPONSE | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
POST_TIME=$(echo $POST_RESPONSE | grep -o '"create_at":[0-9]*' | head -1 | cut -d':' -f2)

echo "✅ 消息已发送"
echo "   消息ID: $POST_ID"
echo "   时间戳: $POST_TIME"
echo ""

# 5. 推进读游标
echo "步骤 5: 推进读游标（标记为已读）"
echo "----------------------------------------"
CURSOR_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"last_post_seq\":$POST_TIME}" \
    http://localhost:8065/api/v4/channels/$CHANNEL_ID/read_cursor)

echo "✅ 读游标已推进"
echo "$CURSOR_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$CURSOR_RESPONSE"
echo ""

# 6. 查询读游标
echo "步骤 6: 查询当前读游标"
echo "----------------------------------------"
GET_CURSOR=$(curl -s -H "Authorization: Bearer $TOKEN" \
    http://localhost:8065/api/v4/channels/$CHANNEL_ID/read_cursor)

echo "✅ 当前读游标:"
echo "$GET_CURSOR" | python3 -m json.tool 2>/dev/null || echo "$GET_CURSOR"
echo ""

# 7. 检查数据库
echo "步骤 7: 验证数据库记录"
echo "----------------------------------------"
echo "SQL 查询命令:"
echo "docker exec -it mattermost-postgres psql -U mmuser -d mattermost -c \\"
echo "  \"SELECT channel_id, user_id, last_post_seq, to_timestamp(updated_at/1000) as updated_time FROM channel_read_cursors WHERE channel_id='$CHANNEL_ID' AND user_id='$USER_ID';\""
echo ""

# 8. 测试 ReadIndexService (如果运行)
echo "步骤 8: 测试 ReadIndexService（可选）"
echo "----------------------------------------"
if curl -s http://localhost:8066/health > /dev/null 2>&1; then
    echo "✅ ReadIndexService 正在运行"
    echo ""
    echo "服务统计:"
    curl -s http://localhost:8066/stats | python3 -m json.tool 2>/dev/null
    echo ""
    
    echo "查询已读用户:"
    curl -s "http://localhost:8066/channels/$CHANNEL_ID/posts/$POST_TIME/readers?limit=10" | python3 -m json.tool 2>/dev/null
else
    echo "⚠️  ReadIndexService 未运行"
    echo "   启动命令: cd read-index-service && go run cmd/server/main.go"
fi
echo ""

echo "=========================================="
echo "✅ 测试完成！"
echo "=========================================="
echo ""
echo "🎯 下一步:"
echo ""
echo "1. 在浏览器中打开: http://localhost:8065"
echo "2. 进入频道: $CHANNEL_NAME"
echo "3. 你应该能看到刚才发送的测试消息"
echo ""
echo "4. 查看数据库中的读游标记录:"
echo "   docker exec -it mattermost-postgres psql -U mmuser -d mattermost"
echo "   SELECT * FROM channel_read_cursors WHERE user_id='$USER_ID' LIMIT 5;"
echo ""
echo "5. 前端 UI 集成（需要手动添加）:"
echo "   - 参考 INTEGRATION_GUIDE.md"
echo "   - 将 PostReadIndicator 组件添加到 Post 组件中"
echo ""
