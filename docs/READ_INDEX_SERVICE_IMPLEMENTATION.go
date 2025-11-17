// ReadIndexService - 高性能读回执索引服务
// 基于 RoaringBitmap 的内存索引，支持大规模频道的已读状态查询

package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"
    "net/http"
    "sync"
    "time"

    "github.com/RoaringBitmap/roaring"
    "github.com/go-redis/redis/v8"
    "github.com/gorilla/mux"
)

// ============================================================================
// 核心数据结构
// ============================================================================

type ReadIndexService struct {
    channels      map[string]*ChannelState
    mu            sync.RWMutex
    redisClient   *redis.Client
    eventConsumer *EventConsumer
}

type ChannelState struct {
    ChannelID   string
    MaxSeq      int64
    UserCursors map[string]int64  // user_id -> last_seq
    UserIndex   map[string]uint32 // user_id -> bitmap index (0..N-1)
    IndexToUser []string          // index -> user_id (反向映射)
    Segments    []*ReadSegment
    WindowSize  int64 // 滑动窗口大小（默认 1000）
    mu          sync.RWMutex
}

type ReadSegment struct {
    StartSeq int64
    EndSeq   int64
    Readers  *roaring.Bitmap // 在此段内"新读到"的用户位图
}

type ReadCursorEvent struct {
    Type        string `json:"type"`
    EventID     string `json:"event_id"`
    ChannelID   string `json:"channel_id"`
    UserID      string `json:"user_id"`
    PrevLastSeq int64  `json:"prev_last_seq"`
    NewLastSeq  int64  `json:"new_last_seq"`
    Timestamp   int64  `json:"timestamp"`
}

type ReadersResponse struct {
    Count     int      `json:"count"`
    Readers   []string `json:"readers"`
    Truncated bool     `json:"truncated"`
}

// ============================================================================
// 服务初始化
// ============================================================================

func NewReadIndexService(redisURL string) *ReadIndexService {
    opt, err := redis.ParseURL(redisURL)
    if err != nil {
        log.Fatalf("Failed to parse Redis URL: %v", err)
    }

    rdb := redis.NewClient(opt)
    ctx := context.Background()
    if err := rdb.Ping(ctx).Err(); err != nil {
        log.Fatalf("Failed to connect to Redis: %v", err)
    }

    service := &ReadIndexService{
        channels:    make(map[string]*ChannelState),
        redisClient: rdb,
    }

    service.eventConsumer = NewEventConsumer(rdb, service)
    return service
}

func (s *ReadIndexService) Start(ctx context.Context) error {
    // 启动事件消费者
    go s.eventConsumer.Start(ctx)

    // 启动定期清理任务
    go s.periodicCleanup(ctx)

    log.Println("ReadIndexService started")
    return nil
}

// ============================================================================
// 事件处理
// ============================================================================

type EventConsumer struct {
    redis   *redis.Client
    service *ReadIndexService
}

func NewEventConsumer(rdb *redis.Client, service *ReadIndexService) *EventConsumer {
    return &EventConsumer{
        redis:   rdb,
        service: service,
    }
}

func (ec *EventConsumer) Start(ctx context.Context) {
    streamName := "read_cursor_events"
    consumerGroup := "read-index-service"
    consumerName := "consumer-1"

    // 创建消费者组（如果不存在）
    ec.redis.XGroupCreateMkStream(ctx, streamName, consumerGroup, "0")

    log.Printf("Starting event consumer: stream=%s, group=%s", streamName, consumerGroup)

    for {
        select {
        case <-ctx.Done():
            return
        default:
            // 读取事件
            streams, err := ec.redis.XReadGroup(ctx, &redis.XReadGroupArgs{
                Group:    consumerGroup,
                Consumer: consumerName,
                Streams:  []string{streamName, ">"},
                Count:    100,
                Block:    time.Second * 5,
            }).Result()

            if err != nil {
                if err != redis.Nil {
                    log.Printf("Error reading from stream: %v", err)
                }
                continue
            }

            // 处理事件
            for _, stream := range streams {
                for _, message := range stream.Messages {
                    ec.processMessage(ctx, streamName, message)
                }
            }
        }
    }
}

func (ec *EventConsumer) processMessage(ctx context.Context, streamName string, msg redis.XMessage) {
    data, ok := msg.Values["data"].(string)
    if !ok {
        log.Printf("Invalid message format: %v", msg.ID)
        ec.redis.XAck(ctx, streamName, "read-index-service", msg.ID)
        return
    }

    var event ReadCursorEvent
    if err := json.Unmarshal([]byte(data), &event); err != nil {
        log.Printf("Failed to unmarshal event: %v", err)
        ec.redis.XAck(ctx, streamName, "read-index-service", msg.ID)
        return
    }

    // 处理事件
    if err := ec.service.HandleReadCursorEvent(&event); err != nil {
        log.Printf("Failed to handle event: %v", err)
        // 不 ACK，稍后重试
        return
    }

    // 确认消息
    ec.redis.XAck(ctx, streamName, "read-index-service", msg.ID)
}

// ============================================================================
// 核心业务逻辑
// ============================================================================

func (s *ReadIndexService) HandleReadCursorEvent(event *ReadCursorEvent) error {
    // 获取或创建频道状态
    s.mu.RLock()
    cs, exists := s.channels[event.ChannelID]
    s.mu.RUnlock()

    if !exists {
        cs = s.createChannelState(event.ChannelID)
    }

    cs.mu.Lock()
    defer cs.mu.Unlock()

    // 确保用户有位图索引
    userIdx, exists := cs.UserIndex[event.UserID]
    if !exists {
        userIdx = uint32(len(cs.IndexToUser))
        cs.UserIndex[event.UserID] = userIdx
        cs.IndexToUser = append(cs.IndexToUser, event.UserID)
    }

    // 获取旧游标位置
    oldSeq := cs.UserCursors[event.UserID]
    if event.NewLastSeq <= oldSeq {
        return nil // 序号没有增加，忽略
    }

    // 更新游标
    cs.UserCursors[event.UserID] = event.NewLastSeq

    // 更新段位图：将用户加入 [oldSeq+1, newSeq] 覆盖的所有段
    for _, seg := range cs.Segments {
        if seg.StartSeq > event.NewLastSeq {
            break
        }
        if seg.EndSeq > oldSeq {
            seg.Readers.Add(userIdx)
        }
    }

    // 更新最大序号并确保段覆盖
    if event.NewLastSeq > cs.MaxSeq {
        cs.MaxSeq = event.NewLastSeq
        cs.ensureSegmentsCover(event.NewLastSeq)
    }

    // 清理旧段
    cs.pruneOldSegments()

    return nil
}

func (s *ReadIndexService) createChannelState(channelID string) *ChannelState {
    s.mu.Lock()
    defer s.mu.Unlock()

    cs := &ChannelState{
        ChannelID:   channelID,
        MaxSeq:      0,
        UserCursors: make(map[string]int64),
        UserIndex:   make(map[string]uint32),
        IndexToUser: make([]string, 0),
        Segments:    make([]*ReadSegment, 0),
        WindowSize:  1000, // 默认窗口大小
    }

    s.channels[channelID] = cs
    return cs
}

// 确保段覆盖到 maxSeq
func (cs *ChannelState) ensureSegmentsCover(maxSeq int64) {
    segmentSize := int64(100) // 每段 100 条消息

    if len(cs.Segments) == 0 {
        cs.Segments = append(cs.Segments, &ReadSegment{
            StartSeq: 0,
            EndSeq:   segmentSize - 1,
            Readers:  roaring.New(),
        })
    }

    lastSeg := cs.Segments[len(cs.Segments)-1]
    for lastSeg.EndSeq < maxSeq {
        newSeg := &ReadSegment{
            StartSeq: lastSeg.EndSeq + 1,
            EndSeq:   lastSeg.EndSeq + segmentSize,
            Readers:  roaring.New(),
        }
        cs.Segments = append(cs.Segments, newSeg)
        lastSeg = newSeg
    }
}

// 清理旧段（滑动窗口）
func (cs *ChannelState) pruneOldSegments() {
    threshold := cs.MaxSeq - cs.WindowSize
    if threshold <= 0 {
        return
    }

    newSegments := make([]*ReadSegment, 0)
    for _, seg := range cs.Segments {
        if seg.EndSeq >= threshold {
            newSegments = append(newSegments, seg)
        }
    }
    cs.Segments = newSegments
}

// ============================================================================
// 查询 API
// ============================================================================

// 获取某条消息的已读用户列表
func (s *ReadIndexService) GetReadersForSeq(channelID string, seq int64, limit int) (*ReadersResponse, error) {
    s.mu.RLock()
    cs, exists := s.channels[channelID]
    s.mu.RUnlock()

    if !exists {
        return &ReadersResponse{Count: 0, Readers: []string{}, Truncated: false}, nil
    }

    cs.mu.RLock()
    defer cs.mu.RUnlock()

    // 合并所有 EndSeq >= seq 的段的位图
    merged := roaring.New()
    for _, seg := range cs.Segments {
        if seg.EndSeq >= seq {
            merged.Or(seg.Readers)
        }
    }

    count := int(merged.GetCardinality())
    readers := make([]string, 0, min(count, limit))

    iter := merged.Iterator()
    for iter.HasNext() && len(readers) < limit {
        userIdx := iter.Next()
        if int(userIdx) < len(cs.IndexToUser) {
            readers = append(readers, cs.IndexToUser[userIdx])
        }
    }

    return &ReadersResponse{
        Count:     count,
        Readers:   readers,
        Truncated: count > limit,
    }, nil
}

// 批量获取已读计数
func (s *ReadIndexService) GetReadCountsForSeqs(channelID string, seqs []int64) (map[int64]int, error) {
    s.mu.RLock()
    cs, exists := s.channels[channelID]
    s.mu.RUnlock()

    result := make(map[int64]int)
    if !exists {
        for _, seq := range seqs {
            result[seq] = 0
        }
        return result, nil
    }

    cs.mu.RLock()
    defer cs.mu.RUnlock()

    for _, seq := range seqs {
        merged := roaring.New()
        for _, seg := range cs.Segments {
            if seg.EndSeq >= seq {
                merged.Or(seg.Readers)
            }
        }
        result[seq] = int(merged.GetCardinality())
    }

    return result, nil
}

// ============================================================================
// HTTP API
// ============================================================================

func (s *ReadIndexService) SetupRoutes() *mux.Router {
    r := mux.NewRouter()

    r.HandleFunc("/health", s.handleHealth).Methods("GET")
    r.HandleFunc("/channels/{channel_id}/posts/{seq}/readers", s.handleGetReaders).Methods("GET")
    r.HandleFunc("/read-counts", s.handleGetReadCounts).Methods("POST")
    r.HandleFunc("/stats", s.handleStats).Methods("GET")

    return r
}

func (s *ReadIndexService) handleHealth(w http.ResponseWriter, r *http.Request) {
    json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (s *ReadIndexService) handleGetReaders(w http.ResponseWriter, r *http.Request) {
    vars := mux.Vars(r)
    channelID := vars["channel_id"]
    
    var seq int64
    fmt.Sscanf(vars["seq"], "%d", &seq)

    limit := 50
    if limitStr := r.URL.Query().Get("limit"); limitStr != "" {
        fmt.Sscanf(limitStr, "%d", &limit)
    }

    resp, err := s.GetReadersForSeq(channelID, seq, limit)
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(resp)
}

func (s *ReadIndexService) handleGetReadCounts(w http.ResponseWriter, r *http.Request) {
    var req struct {
        ChannelID string  `json:"channel_id"`
        Seqs      []int64 `json:"seqs"`
    }

    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    counts, err := s.GetReadCountsForSeqs(req.ChannelID, req.Seqs)
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(counts)
}

func (s *ReadIndexService) handleStats(w http.ResponseWriter, r *http.Request) {
    s.mu.RLock()
    defer s.mu.RUnlock()

    stats := map[string]interface{}{
        "channels_count": len(s.channels),
        "channels":       make([]map[string]interface{}, 0),
    }

    for _, cs := range s.channels {
        cs.mu.RLock()
        channelStats := map[string]interface{}{
            "channel_id":   cs.ChannelID,
            "max_seq":      cs.MaxSeq,
            "users_count":  len(cs.UserCursors),
            "segments":     len(cs.Segments),
            "window_size":  cs.WindowSize,
        }
        cs.mu.RUnlock()
        stats["channels"] = append(stats["channels"].([]map[string]interface{}), channelStats)
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(stats)
}

// ============================================================================
// 定期清理
// ============================================================================

func (s *ReadIndexService) periodicCleanup(ctx context.Context) {
    ticker := time.NewTicker(5 * time.Minute)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            s.cleanupInactiveChannels()
        }
    }
}

func (s *ReadIndexService) cleanupInactiveChannels() {
    s.mu.Lock()
    defer s.mu.Unlock()

    threshold := time.Now().Add(-24 * time.Hour).UnixMilli()
    
    for channelID, cs := range s.channels {
        cs.mu.RLock()
        lastActivity := int64(0)
        for _, seq := range cs.UserCursors {
            if seq > lastActivity {
                lastActivity = seq
            }
        }
        cs.mu.RUnlock()

        // 如果频道 24 小时无活动，移除
        if lastActivity < threshold {
            delete(s.channels, channelID)
            log.Printf("Cleaned up inactive channel: %s", channelID)
        }
    }
}

// ============================================================================
// Main
// ============================================================================

func main() {
    redisURL := "redis://localhost:6379/0"
    if url := os.Getenv("REDIS_URL"); url != "" {
        redisURL = url
    }

    service := NewReadIndexService(redisURL)
    
    ctx := context.Background()
    if err := service.Start(ctx); err != nil {
        log.Fatalf("Failed to start service: %v", err)
    }

    router := service.SetupRoutes()
    
    port := "8066"
    if p := os.Getenv("PORT"); p != "" {
        port = p
    }

    log.Printf("ReadIndexService listening on :%s", port)
    if err := http.ListenAndServe(":"+port, router); err != nil {
        log.Fatalf("Server failed: %v", err)
    }
}

func min(a, b int) int {
    if a < b {
        return a
    }
    return b
}
