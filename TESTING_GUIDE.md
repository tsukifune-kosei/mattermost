# 读回执功能测试指南

## 前置条件

1. **Mattermost Server 已运行**
   ```bash
   cd server
   make run-server
   ```

2. **获取访问令牌**
   - 登录 Mattermost Web
   - 个人设置 → 安全 → 个人访问令牌
   - 创建新令牌并保存

## 测试步骤

### 1. 测试 Server API

使用提供的测试脚本：

```bash
export MATTERMOST_TOKEN="your-token-here"
export TEST_CHANNEL_ID="your-channel-id"  # 可选
./test-read-receipts.sh
```

或手动测试：

```bash
# 设置变量
TOKEN="your-token-here"
CHANNEL_ID="your-channel-id"
API_URL="http://localhost:8065/api/v4"

# 推进读游标
curl -X POST "$API_URL/channels/$CHANNEL_ID/read_cursor" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"last_post_seq": 1700000000000}'

# 获取读游标
curl "$API_URL/channels/$CHANNEL_ID/read_cursor" \
  -H "Authorization: Bearer $TOKEN"
```

### 2. 验证数据库

连接到 PostgreSQL：

```bash
# 使用 Docker
docker exec -it mattermost-postgres psql -U mmuser -d mattermost

# 或直接连接
psql -h localhost -U mmuser -d mattermost
```

查询读游标记录：

```sql
-- 查看所有读游标
SELECT * FROM channel_read_cursors ORDER BY updated_at DESC LIMIT 10;

-- 查看特定频道的读游标
SELECT 
    c.display_name as channel_name,
    u.username,
    crc.last_post_seq,
    to_timestamp(crc.updated_at/1000) as updated_time
FROM channel_read_cursors crc
JOIN channels c ON c.id = crc.channel_id
JOIN users u ON u.id = crc.user_id
WHERE crc.channel_id = 'your-channel-id'
ORDER BY crc.updated_at DESC;

-- 统计
SELECT 
    COUNT(*) as total_cursors,
    COUNT(DISTINCT channel_id) as channels_count,
    COUNT(DISTINCT user_id) as users_count
FROM channel_read_cursors;
```

### 3. 测试 ReadIndexService

#### 启动服务

```bash
cd read-index-service

# 方式 1: 直接运行
export REDIS_URL="redis://localhost:6379/0"
go run cmd/server/main.go

# 方式 2: 使用 Docker Compose
docker-compose up -d
```

#### 测试 API

```bash
# 健康检查
curl http://localhost:8066/health

# 查看统计
curl http://localhost:8066/stats | jq

# 查询已读用户（需要先有数据）
curl "http://localhost:8066/channels/CHANNEL_ID/posts/1700000000000/readers?limit=10" | jq

# 批量查询已读计数
curl -X POST http://localhost:8066/read-counts \
  -H "Content-Type: application/json" \
  -d '{
    "channel_id": "CHANNEL_ID",
    "seqs": [1700000000000, 1700000005000]
  }' | jq
```

### 4. 测试事件流（Redis Stream）

#### 查看 Redis Stream

```bash
# 连接 Redis
redis-cli

# 查看 stream 信息
XINFO STREAM read_cursor_events

# 查看最近的事件
XREAD COUNT 10 STREAMS read_cursor_events 0

# 查看消费者组
XINFO GROUPS read_cursor_events
```

#### 手动发送测试事件

```bash
# 在 Redis 中手动添加事件
redis-cli XADD read_cursor_events * data '{
  "type": "channel_read_advanced",
  "event_id": "test123",
  "channel_id": "your-channel-id",
  "user_id": "your-user-id",
  "prev_last_seq": 0,
  "new_last_seq": 1700000000000,
  "timestamp": 1700000000000
}'
```

### 5. 集成测试流程

完整的端到端测试：

```bash
# 1. 确保所有服务运行
# - Mattermost Server (localhost:8065)
# - Redis (localhost:6379)
# - ReadIndexService (localhost:8066)

# 2. 创建测试数据
# 登录 Mattermost，发送几条消息

# 3. 推进读游标
curl -X POST "http://localhost:8065/api/v4/channels/$CHANNEL_ID/read_cursor" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"last_post_seq\": $(date +%s)000}"

# 4. 等待几秒让 ReadIndexService 处理事件

# 5. 查询 ReadIndexService
curl "http://localhost:8066/channels/$CHANNEL_ID/posts/$(date +%s)000/readers" | jq

# 6. 验证数据一致性
# 检查数据库中的游标记录
# 检查 ReadIndexService 的统计信息
```

## 性能测试

### 压力测试脚本

```bash
#!/bin/bash
# 并发推进读游标

CHANNEL_ID="your-channel-id"
TOKEN="your-token"
CONCURRENT=10
REQUESTS=100

for i in $(seq 1 $CONCURRENT); do
  (
    for j in $(seq 1 $REQUESTS); do
      curl -s -X POST "http://localhost:8065/api/v4/channels/$CHANNEL_ID/read_cursor" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"last_post_seq\": $(date +%s%N | cut -b1-13)}" > /dev/null
      echo "Worker $i: Request $j completed"
    done
  ) &
done

wait
echo "All requests completed"
```

### 监控指标

```bash
# 查看 ReadIndexService 内存使用
docker stats read-index-service

# 查看 Redis 内存
redis-cli INFO memory

# 查看数据库大小
psql -U mmuser -d mattermost -c "
SELECT 
    pg_size_pretty(pg_total_relation_size('channel_read_cursors')) as table_size,
    COUNT(*) as row_count
FROM channel_read_cursors;
"
```

## 故障排查

### 常见问题

1. **API 返回 404**
   - 检查迁移是否执行：`SELECT * FROM db_migrations WHERE version = 147;`
   - 重新运行迁移：`make run-server` 会自动执行

2. **ReadIndexService 无法连接 Redis**
   - 检查 Redis 是否运行：`redis-cli ping`
   - 检查 REDIS_URL 配置

3. **事件未被消费**
   - 检查 ReadIndexService 日志
   - 检查 Redis Stream：`XINFO STREAM read_cursor_events`
   - 检查消费者组：`XINFO GROUPS read_cursor_events`

4. **数据不一致**
   - 清理 Redis Stream：`DEL read_cursor_events`
   - 重启 ReadIndexService
   - 重新推进游标

### 日志查看

```bash
# Mattermost Server 日志
tail -f server/logs/mattermost.log | grep -i "read.*cursor"

# ReadIndexService 日志
docker logs -f read-index-service

# Redis 日志
docker logs -f mattermost-redis
```

## 清理测试数据

```bash
# 清理数据库
psql -U mmuser -d mattermost -c "TRUNCATE channel_read_cursors;"

# 清理 Redis Stream
redis-cli DEL read_cursor_events

# 重启 ReadIndexService
docker-compose restart read-index-service
```

## 下一步

测试通过后，继续实现前端 UI：
1. Redux Actions 和 Reducers
2. PostReadIndicator 组件
3. PostReadReceiptsModal 组件
4. WebSocket 事件监听
