# 如何查看读回执功能

## 🚀 快速开始

### 方法 1: 使用测试脚本（推荐）

```bash
chmod +x quick-test.sh
./quick-test.sh
```

脚本会引导你：
1. 输入访问令牌
2. 自动发送测试消息
3. 推进读游标
4. 验证功能是否正常

### 方法 2: 手动测试 API

#### 步骤 1: 获取访问令牌

1. 打开浏览器访问 `http://localhost:8065`
2. 登录 Mattermost
3. 点击右上角头像 → **个人设置**
4. **安全** → **个人访问令牌**
5. 点击 **创建令牌**，输入描述（如 "测试读回执"）
6. 复制生成的令牌

#### 步骤 2: 设置环境变量

```bash
export TOKEN="你的令牌"
export API="http://localhost:8065/api/v4"
```

#### 步骤 3: 获取频道 ID

```bash
# 获取你的团队
curl -H "Authorization: Bearer $TOKEN" $API/users/me/teams

# 获取频道列表（替换 TEAM_ID）
curl -H "Authorization: Bearer $TOKEN" $API/users/me/teams/TEAM_ID/channels

# 记下一个频道的 ID
export CHANNEL_ID="频道ID"
```

#### 步骤 4: 发送测试消息

```bash
# 发送消息
curl -X POST $API/posts \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"channel_id\": \"$CHANNEL_ID\",
    \"message\": \"测试读回执功能\"
  }"

# 记下返回的 create_at 时间戳
```

#### 步骤 5: 推进读游标

```bash
# 使用消息的 create_at 作为 last_post_seq
curl -X POST "$API/channels/$CHANNEL_ID/read_cursor" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"last_post_seq\": 1700000000000
  }"
```

#### 步骤 6: 查询读游标

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "$API/channels/$CHANNEL_ID/read_cursor"
```

---

## 🔍 验证功能

### 1. 检查数据库

```bash
# 连接数据库
docker exec -it mattermost-postgres psql -U mmuser -d mattermost

# 查看读游标记录
SELECT 
    channel_id,
    user_id,
    last_post_seq,
    to_timestamp(updated_at/1000) as updated_time
FROM channel_read_cursors
ORDER BY updated_at DESC
LIMIT 10;
```

### 2. 检查 ReadIndexService（如果启动）

```bash
# 健康检查
curl http://localhost:8066/health

# 查看统计
curl http://localhost:8066/stats | jq

# 查询已读用户（需要先有数据）
curl "http://localhost:8066/channels/CHANNEL_ID/posts/TIMESTAMP/readers?limit=10" | jq
```

### 3. 检查 Redis Stream

```bash
# 连接 Redis
redis-cli

# 查看 stream
XINFO STREAM read_cursor_events

# 查看最近的事件
XREAD COUNT 10 STREAMS read_cursor_events 0
```

---

## 🎨 前端 UI 展示

### 当前状态

✅ **后端完全可用** - API 正常工作  
✅ **前端组件已创建** - 但未集成到 Post 组件  
⏳ **需要手动集成** - 参考下面的步骤

### 快速集成到前端

由于前端组件还没有完全集成，你有两个选择：

#### 选项 A: 使用浏览器控制台测试

1. 打开 Mattermost Web (`http://localhost:8065`)
2. 打开浏览器开发者工具（F12）
3. 在控制台中运行：

```javascript
// 获取当前频道 ID
const channelId = window.location.pathname.split('/')[3];

// 调用 API 推进读游标
fetch(`/api/v4/channels/${channelId}/read_cursor`, {
    method: 'POST',
    headers: {
        'Content-Type': 'application/json',
        'X-Requested-With': 'XMLHttpRequest'
    },
    credentials: 'include',
    body: JSON.stringify({
        last_post_seq: Date.now()
    })
})
.then(r => r.json())
.then(data => console.log('读游标已更新:', data));

// 查询读游标
fetch(`/api/v4/channels/${channelId}/read_cursor`, {
    credentials: 'include'
})
.then(r => r.json())
.then(data => console.log('当前读游标:', data));
```

#### 选项 B: 完整集成（需要修改代码）

参考 `INTEGRATION_GUIDE.md` 完成以下步骤：

1. **注册 Reducer**
   - 编辑 `webapp/channels/src/reducers/views/index.ts`
   - 添加 `readReceipts` reducer

2. **注册 WebSocket 事件**
   - 编辑 `webapp/channels/src/actions/websocket_actions.tsx`
   - 添加 `read_cursor_advanced` 事件处理

3. **集成到 Post 组件**
   - 编辑 `webapp/channels/src/components/post_view/post/post.tsx`
   - 添加 `PostReadIndicator` 组件

4. **重新编译前端**
   ```bash
   cd webapp
   npm run build
   ```

---

## 📊 预期效果

### 后端功能（已完成）✅

当你推进读游标后：

1. **数据库中会有记录**
   ```sql
   channel_id | user_id | last_post_seq | updated_at
   -----------+---------+---------------+------------
   abc123     | user1   | 1700000000000 | 2024-11-17...
   ```

2. **API 返回正确数据**
   ```json
   {
     "channel_id": "abc123",
     "user_id": "user1",
     "last_post_seq": 1700000000000,
     "updated_at": 1700000000000
   }
   ```

3. **WebSocket 事件发送**
   - 其他用户会收到 `read_cursor_advanced` 事件

4. **ReadIndexService 更新索引**（如果运行）
   - 内存中的位图索引会更新
   - 可以查询已读用户列表

### 前端 UI（需要集成）⏳

完成集成后，你会看到：

1. **消息下方显示已读计数**
   ```
   [消息内容]
   ✓✓ 3 read
   ```

2. **点击查看已读用户列表**
   ```
   Read by 3 people
   ----------------
   👤 John Doe (@john)
   👤 Jane Smith (@jane)
   👤 Bob Wilson (@bob)
   ```

3. **实时更新**
   - 当其他用户阅读消息时，计数自动增加

---

## 🐛 故障排查

### API 返回 404

```bash
# 检查迁移是否执行
docker exec -it mattermost-postgres psql -U mmuser -d mattermost \
  -c "SELECT version FROM db_migrations WHERE version = 147;"

# 如果没有记录，重启 Server
cd server && make stop-server && make run-server
```

### 数据库中没有记录

```bash
# 检查 API 是否返回错误
curl -v -X POST "$API/channels/$CHANNEL_ID/read_cursor" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"last_post_seq": 1700000000000}'

# 查看 Server 日志
tail -f server/logs/mattermost.log | grep -i "read.*cursor"
```

### ReadIndexService 无法连接

```bash
# 检查 Redis 是否运行
redis-cli ping

# 检查 ReadIndexService 日志
docker logs read-index-service  # 如果用 Docker
# 或查看终端输出
```

---

## 🎯 下一步

1. **测试后端功能** ✅
   ```bash
   ./quick-test.sh
   ```

2. **验证数据存储** ✅
   - 检查数据库
   - 检查 Redis Stream

3. **集成前端 UI** ⏳
   - 参考 `INTEGRATION_GUIDE.md`
   - 修改 Post 组件
   - 重新编译

4. **启动 ReadIndexService** ⏳
   ```bash
   cd read-index-service
   go run cmd/server/main.go
   ```

5. **完整测试** ⏳
   - 多用户测试
   - 实时更新测试
   - 性能测试

---

## 💡 提示

- 后端功能已经**完全可用**，可以通过 API 测试
- 前端 UI 组件已经**创建完成**，但需要手动集成
- 使用 `quick-test.sh` 可以快速验证所有后端功能
- 参考 `INTEGRATION_GUIDE.md` 了解如何完成前端集成

**祝测试顺利！** 🎊
