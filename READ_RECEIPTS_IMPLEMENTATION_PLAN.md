# Mattermost 消息已读状态和已读用户列表功能实现方案

## 功能概述

为 Mattermost 添加以下人性化功能：
1. **消息已读状态**：显示每条消息是否已被其他用户阅读
2. **已读用户列表**：点击消息可查看哪些用户已读该消息

## 现状分析

### 已有的相关功能

Mattermost 目前已经实现了：
- ✅ **频道级别的未读计数**：通过 `ChannelMember.LastViewedAt` 追踪用户最后查看频道的时间
- ✅ **消息未读标记**：用户可以手动标记消息为未读（`setPostUnread` API）
- ✅ **线程已读追踪**：支持 Collapsed Threads 模式下的线程已读状态
- ✅ **WebSocket 实时推送**：已有 `WebsocketEventPostUnread` 等事件

### 缺失的功能

- ❌ **消息级别的已读追踪**：没有记录每个用户对每条消息的阅读状态
- ❌ **已读用户列表**：无法查看谁已读了某条消息
- ❌ **已读回执 UI**：前端没有显示消息已读状态的界面

## 技术实现方案

### 1. 数据库设计

#### 1.1 新增表：`PostReadReceipts`

```sql
CREATE TABLE IF NOT EXISTS PostReadReceipts (
    PostId varchar(26) NOT NULL,
    UserId varchar(26) NOT NULL,
    ReadAt bigint NOT NULL,
    PRIMARY KEY (PostId, UserId),
    INDEX idx_postreadreceipts_postid (PostId),
    INDEX idx_postreadreceipts_userid (UserId),
    INDEX idx_postreadreceipts_readat (ReadAt)
);
```

**字段说明**：
- `PostId`: 消息 ID
- `UserId`: 用户 ID
- `ReadAt`: 阅读时间戳（毫秒）

**索引策略**：
- 主键：`(PostId, UserId)` - 确保唯一性
- `PostId` 索引：快速查询某条消息的所有已读用户
- `UserId` 索引：快速查询某用户的已读记录
- `ReadAt` 索引：支持按时间范围清理旧数据

#### 1.2 数据保留策略

为避免表过大，建议：
- 只保留最近 30 天的已读记录
- 定期清理旧数据（通过定时任务）
- 可配置保留天数（系统设置）

### 2. 后端实现

#### 2.1 Model 层（`server/public/model/`）

**新增文件：`post_read_receipt.go`**

```go
package model

type PostReadReceipt struct {
    PostId string `json:"post_id"`
    UserId string `json:"user_id"`
    ReadAt int64  `json:"read_at"`
}

type PostReadReceiptList struct {
    PostId      string              `json:"post_id"`
    TotalReads  int                 `json:"total_reads"`
    ReadBy      []*PostReadReceipt  `json:"read_by"`
}

func (p *PostReadReceipt) IsValid() *AppError {
    if !IsValidId(p.PostId) {
        return NewAppError("PostReadReceipt.IsValid", "model.post_read_receipt.is_valid.post_id.app_error", nil, "", http.StatusBadRequest)
    }
    if !IsValidId(p.UserId) {
        return NewAppError("PostReadReceipt.IsValid", "model.post_read_receipt.is_valid.user_id.app_error", nil, "", http.StatusBadRequest)
    }
    if p.ReadAt == 0 {
        return NewAppError("PostReadReceipt.IsValid", "model.post_read_receipt.is_valid.read_at.app_error", nil, "", http.StatusBadRequest)
    }
    return nil
}
```

#### 2.2 Store 层（`server/channels/store/`）

**在 `store.go` 中添加接口：**

```go
type PostReadReceiptStore interface {
    // 保存已读记录
    SaveReadReceipt(receipt *model.PostReadReceipt) error
    
    // 批量保存已读记录（用户查看频道时）
    SaveReadReceiptsForChannel(userId string, channelId string, beforeTime int64) error
    
    // 获取某条消息的已读用户列表
    GetReadReceiptsForPost(postId string, page int, perPage int) ([]*model.PostReadReceipt, error)
    
    // 获取某条消息的已读用户数
    GetReadCountForPost(postId string) (int64, error)
    
    // 批量获取多条消息的已读数（用于列表显示）
    GetReadCountsForPosts(postIds []string) (map[string]int64, error)
    
    // 检查用户是否已读某条消息
    HasUserReadPost(postId string, userId string) (bool, error)
    
    // 清理旧数据
    DeleteOldReadReceipts(olderThan int64) error
}
```

**实现：`sqlstore/post_read_receipt_store.go`**

```go
package sqlstore

type SqlPostReadReceiptStore struct {
    *SqlStore
}

func (s SqlPostReadReceiptStore) SaveReadReceipt(receipt *model.PostReadReceipt) error {
    query := `
        INSERT INTO PostReadReceipts (PostId, UserId, ReadAt)
        VALUES (:PostId, :UserId, :ReadAt)
        ON DUPLICATE KEY UPDATE ReadAt = :ReadAt
    `
    _, err := s.GetMaster().NamedExec(query, receipt)
    return err
}

func (s SqlPostReadReceiptStore) GetReadReceiptsForPost(postId string, page int, perPage int) ([]*model.PostReadReceipt, error) {
    var receipts []*model.PostReadReceipt
    query := `
        SELECT prr.*, u.Username, u.FirstName, u.LastName
        FROM PostReadReceipts prr
        JOIN Users u ON prr.UserId = u.Id
        WHERE prr.PostId = ?
        ORDER BY prr.ReadAt DESC
        LIMIT ? OFFSET ?
    `
    err := s.GetReplica().Select(&receipts, query, postId, perPage, page*perPage)
    return receipts, err
}

func (s SqlPostReadReceiptStore) GetReadCountsForPosts(postIds []string) (map[string]int64, error) {
    if len(postIds) == 0 {
        return map[string]int64{}, nil
    }
    
    query, args, err := sqlx.In(`
        SELECT PostId, COUNT(*) as count
        FROM PostReadReceipts
        WHERE PostId IN (?)
        GROUP BY PostId
    `, postIds)
    
    if err != nil {
        return nil, err
    }
    
    var results []struct {
        PostId string `db:"PostId"`
        Count  int64  `db:"count"`
    }
    
    err = s.GetReplica().Select(&results, s.GetReplica().Rebind(query), args...)
    if err != nil {
        return nil, err
    }
    
    counts := make(map[string]int64)
    for _, r := range results {
        counts[r.PostId] = r.Count
    }
    
    return counts, nil
}
```

#### 2.3 App 层（`server/channels/app/`）

**在 `post.go` 中添加方法：**

```go
// 用户查看频道时自动标记消息为已读
func (a *App) MarkPostsAsReadForUser(rctx request.CTX, userId string, channelId string, timestamp int64) *model.AppError {
    // 获取用户在该频道的最后查看时间
    member, err := a.GetChannelMember(rctx, channelId, userId)
    if err != nil {
        return err
    }
    
    lastViewedAt := member.LastViewedAt
    
    // 获取该时间段内的所有消息
    posts, err := a.Srv().Store().Post().GetPostsSince(rctx, channelId, lastViewedAt, false, false)
    if err != nil {
        return model.NewAppError("MarkPostsAsReadForUser", "app.post.mark_as_read.app_error", nil, "", http.StatusInternalServerError).Wrap(err)
    }
    
    // 批量保存已读记录
    for _, post := range posts.Posts {
        // 不记录自己发送的消息
        if post.UserId == userId {
            continue
        }
        
        receipt := &model.PostReadReceipt{
            PostId: post.Id,
            UserId: userId,
            ReadAt: timestamp,
        }
        
        if err := a.Srv().Store().PostReadReceipt().SaveReadReceipt(receipt); err != nil {
            rctx.Logger().Error("Failed to save read receipt", mlog.Err(err))
        }
    }
    
    // 发送 WebSocket 事件通知其他用户
    a.publishPostReadEvent(rctx, channelId, userId, posts.Order)
    
    return nil
}

// 获取消息的已读用户列表
func (a *App) GetPostReadReceipts(rctx request.CTX, postId string, page int, perPage int) (*model.PostReadReceiptList, *model.AppError) {
    receipts, err := a.Srv().Store().PostReadReceipt().GetReadReceiptsForPost(postId, page, perPage)
    if err != nil {
        return nil, model.NewAppError("GetPostReadReceipts", "app.post.get_read_receipts.app_error", nil, "", http.StatusInternalServerError).Wrap(err)
    }
    
    count, err := a.Srv().Store().PostReadReceipt().GetReadCountForPost(postId)
    if err != nil {
        return nil, model.NewAppError("GetPostReadReceipts", "app.post.get_read_count.app_error", nil, "", http.StatusInternalServerError).Wrap(err)
    }
    
    return &model.PostReadReceiptList{
        PostId:     postId,
        TotalReads: int(count),
        ReadBy:     receipts,
    }, nil
}

// 发布已读事件
func (a *App) publishPostReadEvent(rctx request.CTX, channelId string, userId string, postIds []string) {
    message := model.NewWebSocketEvent(model.WebsocketEventPostRead, "", channelId, "", nil, "")
    message.Add("user_id", userId)
    message.Add("post_ids", postIds)
    a.Publish(message)
}
```

#### 2.4 API 层（`server/channels/api4/`）

**在 `post.go` 中添加路由和处理函数：**

```go
func (api *API) InitPost() {
    // ... 现有路由 ...
    
    // 新增路由
    api.BaseRoutes.Post.Handle("/read_receipts", api.APISessionRequired(getPostReadReceipts)).Methods(http.MethodGet)
    api.BaseRoutes.Posts.Handle("/read_counts", api.APISessionRequired(getPostsReadCounts)).Methods(http.MethodPost)
}

// 获取消息的已读用户列表
func getPostReadReceipts(c *Context, w http.ResponseWriter, r *http.Request) {
    c.RequirePostId()
    if c.Err != nil {
        return
    }
    
    // 检查权限
    if !c.App.SessionHasPermissionToChannelByPost(*c.AppContext.Session(), c.Params.PostId, model.PermissionReadChannelContent) {
        c.SetPermissionError(model.PermissionReadChannelContent)
        return
    }
    
    page := c.Params.Page
    perPage := c.Params.PerPage
    
    receipts, err := c.App.GetPostReadReceipts(c.AppContext, c.Params.PostId, page, perPage)
    if err != nil {
        c.Err = err
        return
    }
    
    if err := json.NewEncoder(w).Encode(receipts); err != nil {
        c.Logger.Warn("Error while writing response", mlog.Err(err))
    }
}

// 批量获取消息的已读数
func getPostsReadCounts(c *Context, w http.ResponseWriter, r *http.Request) {
    var postIds []string
    if jsonErr := json.NewDecoder(r.Body).Decode(&postIds); jsonErr != nil {
        c.SetInvalidParamWithErr("post_ids", jsonErr)
        return
    }
    
    if len(postIds) == 0 {
        c.SetInvalidParam("post_ids")
        return
    }
    
    counts, err := c.App.Srv().Store().PostReadReceipt().GetReadCountsForPosts(postIds)
    if err != nil {
        c.Err = model.NewAppError("getPostsReadCounts", "api.post.get_read_counts.app_error", nil, "", http.StatusInternalServerError).Wrap(err)
        return
    }
    
    if err := json.NewEncoder(w).Encode(counts); err != nil {
        c.Logger.Warn("Error while writing response", mlog.Err(err))
    }
}
```

**修改 `channel.go` 中的 `viewChannel` 函数：**

```go
func viewChannel(c *Context, w http.ResponseWriter, r *http.Request) {
    // ... 现有代码 ...
    
    // 在更新 LastViewedAt 后，标记消息为已读
    if appErr == nil {
        timestamp := model.GetMillis()
        if err := c.App.MarkPostsAsReadForUser(c.AppContext, c.AppContext.Session().UserId, view.ChannelId, timestamp); err != nil {
            c.Logger.Warn("Failed to mark posts as read", mlog.Err(err))
        }
    }
    
    // ... 现有代码 ...
}
```

### 3. 前端实现

#### 3.1 Redux Actions（`webapp/channels/src/packages/mattermost-redux/src/actions/`）

**新增文件：`post_read_receipts.ts`**

```typescript
import {Client4} from 'mattermost-redux/client';
import {ActionFunc} from 'mattermost-redux/types/actions';
import {PostReadReceiptList} from 'mattermost-redux/types/posts';

export function getPostReadReceipts(postId: string, page = 0, perPage = 60): ActionFunc {
    return async (dispatch, getState) => {
        let data: PostReadReceiptList;
        try {
            data = await Client4.getPostReadReceipts(postId, page, perPage);
        } catch (error) {
            return {error};
        }

        dispatch({
            type: 'RECEIVED_POST_READ_RECEIPTS',
            data: {
                postId,
                receipts: data,
            },
        });

        return {data};
    };
}

export function getPostsReadCounts(postIds: string[]): ActionFunc {
    return async (dispatch) => {
        let data: Record<string, number>;
        try {
            data = await Client4.getPostsReadCounts(postIds);
        } catch (error) {
            return {error};
        }

        dispatch({
            type: 'RECEIVED_POSTS_READ_COUNTS',
            data,
        });

        return {data};
    };
}
```

#### 3.2 Client（`webapp/platform/client/src/client4.ts`）

```typescript
// 添加到 Client4 类中
getPostReadReceipts = (postId: string, page = 0, perPage = 60) => {
    return this.doFetch<PostReadReceiptList>(
        `${this.getPostRoute(postId)}/read_receipts${buildQueryString({page, per_page: perPage})}`,
        {method: 'get'}
    );
};

getPostsReadCounts = (postIds: string[]) => {
    return this.doFetch<Record<string, number>>(
        `${this.getPostsRoute()}/read_counts`,
        {method: 'post', body: JSON.stringify(postIds)}
    );
};
```

#### 3.3 UI 组件

**新增组件：`PostReadReceiptsModal.tsx`**

```typescript
import React, {useEffect, useState} from 'react';
import {useDispatch, useSelector} from 'react-redux';
import {Modal} from 'react-bootstrap';

import {getPostReadReceipts} from 'mattermost-redux/actions/post_read_receipts';
import {PostReadReceiptList} from 'mattermost-redux/types/posts';

import Avatar from 'components/widgets/users/avatar';
import Timestamp from 'components/timestamp';

interface Props {
    postId: string;
    onHide: () => void;
}

const PostReadReceiptsModal: React.FC<Props> = ({postId, onHide}) => {
    const dispatch = useDispatch();
    const [receipts, setReceipts] = useState<PostReadReceiptList | null>(null);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        const fetchReceipts = async () => {
            setLoading(true);
            const result = await dispatch(getPostReadReceipts(postId));
            if (result.data) {
                setReceipts(result.data);
            }
            setLoading(false);
        };

        fetchReceipts();
    }, [postId, dispatch]);

    return (
        <Modal
            show={true}
            onHide={onHide}
            dialogClassName='post-read-receipts-modal'
        >
            <Modal.Header closeButton={true}>
                <Modal.Title>
                    {'已读用户'}
                    {receipts && ` (${receipts.total_reads})`}
                </Modal.Title>
            </Modal.Header>
            <Modal.Body>
                {loading ? (
                    <div className='loading-spinner'/>
                ) : (
                    <div className='read-receipts-list'>
                        {receipts?.read_by.map((receipt) => (
                            <div
                                key={receipt.user_id}
                                className='read-receipt-item'
                            >
                                <Avatar
                                    userId={receipt.user_id}
                                    size='sm'
                                />
                                <div className='user-info'>
                                    <span className='username'>
                                        {receipt.username}
                                    </span>
                                    <Timestamp
                                        value={receipt.read_at}
                                        className='read-time'
                                    />
                                </div>
                            </div>
                        ))}
                    </div>
                )}
            </Modal.Body>
        </Modal>
    );
};

export default PostReadReceiptsModal;
```

**修改 `Post` 组件，添加已读指示器：**

```typescript
// 在 Post 组件中添加
import PostReadIndicator from './post_read_indicator';

// 在渲染中添加
<PostReadIndicator
    postId={post.id}
    channelId={post.channel_id}
/>
```

**新增组件：`PostReadIndicator.tsx`**

```typescript
import React, {useEffect, useState} from 'react';
import {useDispatch} from 'react-redux';
import {OverlayTrigger, Tooltip} from 'react-bootstrap';

import {getPostsReadCounts} from 'mattermost-redux/actions/post_read_receipts';

interface Props {
    postId: string;
    channelId: string;
}

const PostReadIndicator: React.FC<Props> = ({postId, channelId}) => {
    const dispatch = useDispatch();
    const [readCount, setReadCount] = useState(0);
    const [showModal, setShowModal] = useState(false);

    useEffect(() => {
        const fetchReadCount = async () => {
            const result = await dispatch(getPostsReadCounts([postId]));
            if (result.data && result.data[postId]) {
                setReadCount(result.data[postId]);
            }
        };

        fetchReadCount();

        // 监听 WebSocket 事件
        // TODO: 实现 WebSocket 监听
    }, [postId, dispatch]);

    if (readCount === 0) {
        return null;
    }

    const tooltip = (
        <Tooltip id={`read-count-${postId}`}>
            {`${readCount} 人已读`}
        </Tooltip>
    );

    return (
        <>
            <OverlayTrigger
                placement='top'
                overlay={tooltip}
            >
                <button
                    className='post-read-indicator'
                    onClick={() => setShowModal(true)}
                >
                    <i className='icon icon-check-all'/>
                    <span>{readCount}</span>
                </button>
            </OverlayTrigger>

            {showModal && (
                <PostReadReceiptsModal
                    postId={postId}
                    onHide={() => setShowModal(false)}
                />
            )}
        </>
    );
};

export default PostReadIndicator;
```

#### 3.4 样式（`webapp/channels/src/sass/`）

**新增文件：`components/_post-read-receipts.scss`**

```scss
.post-read-indicator {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 6px;
    border: none;
    background: transparent;
    color: rgba(var(--center-channel-color-rgb), 0.56);
    font-size: 12px;
    cursor: pointer;
    border-radius: 4px;
    transition: all 0.15s ease;

    &:hover {
        background: rgba(var(--center-channel-color-rgb), 0.08);
        color: rgba(var(--center-channel-color-rgb), 0.72);
    }

    .icon {
        font-size: 14px;
    }
}

.post-read-receipts-modal {
    .modal-dialog {
        max-width: 480px;
    }

    .read-receipts-list {
        max-height: 400px;
        overflow-y: auto;
    }

    .read-receipt-item {
        display: flex;
        align-items: center;
        gap: 12px;
        padding: 8px 12px;
        border-radius: 4px;
        transition: background 0.15s ease;

        &:hover {
            background: rgba(var(--center-channel-color-rgb), 0.04);
        }

        .user-info {
            flex: 1;
            display: flex;
            flex-direction: column;
            gap: 2px;

            .username {
                font-weight: 600;
                color: var(--center-channel-color);
            }

            .read-time {
                font-size: 12px;
                color: rgba(var(--center-channel-color-rgb), 0.56);
            }
        }
    }
}
```

### 4. WebSocket 实时更新

#### 4.1 后端事件定义

**在 `model/websocket_message.go` 中添加：**

```go
const (
    // ... 现有常量 ...
    WebsocketEventPostRead = "post_read"
)
```

#### 4.2 前端 WebSocket 监听

**在 `webapp/channels/src/actions/websocket_actions.tsx` 中添加：**

```typescript
function handlePostReadEvent(msg: WebSocketMessage) {
    const {user_id: userId, post_ids: postIds} = msg.data;
    
    dispatch({
        type: 'POST_READ_EVENT',
        data: {
            userId,
            postIds,
        },
    });
    
    // 更新已读计数
    dispatch(getPostsReadCounts(postIds));
}

// 在 WebSocket 事件处理器中注册
case WebsocketEvents.POST_READ:
    handlePostReadEvent(msg);
    break;
```

### 5. 配置选项

#### 5.1 系统设置

**在 `config/config.go` 中添加：**

```go
type ServiceSettings struct {
    // ... 现有字段 ...
    
    // 是否启用已读回执功能
    EnableReadReceipts *bool
    
    // 已读记录保留天数
    ReadReceiptsRetentionDays *int
}
```

**默认值：**
```go
EnableReadReceipts: NewBool(true),
ReadReceiptsRetentionDays: NewInt(30),
```

#### 5.2 用户设置

允许用户在个人设置中控制：
- 是否发送已读回执
- 是否显示他人的已读状态

### 6. 性能优化

#### 6.1 批量操作
- 用户查看频道时，批量保存已读记录
- 批量查询多条消息的已读数

#### 6.2 缓存策略
- 使用 Redis 缓存已读计数
- 设置合理的缓存过期时间（如 5 分钟）

#### 6.3 数据库优化
- 使用 `ON DUPLICATE KEY UPDATE` 避免重复插入
- 定期清理旧数据，保持表大小可控
- 考虑分表策略（按月份）

#### 6.4 前端优化
- 虚拟滚动加载已读用户列表
- 防抖处理 WebSocket 事件
- 只在可见区域的消息上显示已读指示器

### 7. 数据迁移

**创建迁移文件：`000XXX_create_post_read_receipts.up.sql`**

```sql
CREATE TABLE IF NOT EXISTS PostReadReceipts (
    PostId varchar(26) NOT NULL,
    UserId varchar(26) NOT NULL,
    ReadAt bigint NOT NULL,
    PRIMARY KEY (PostId, UserId)
);

CREATE INDEX idx_postreadreceipts_postid ON PostReadReceipts(PostId);
CREATE INDEX idx_postreadreceipts_userid ON PostReadReceipts(UserId);
CREATE INDEX idx_postreadreceipts_readat ON PostReadReceipts(ReadAt);
```

### 8. 测试计划

#### 8.1 单元测试
- Model 验证测试
- Store 层 CRUD 测试
- App 层业务逻辑测试

#### 8.2 集成测试
- API 端点测试
- WebSocket 事件测试
- 权限验证测试

#### 8.3 E2E 测试
- 用户查看消息后显示已读
- 点击查看已读用户列表
- 实时更新已读状态

#### 8.4 性能测试
- 大量消息的已读记录写入性能
- 已读用户列表查询性能
- WebSocket 事件推送性能

### 9. 实施步骤

1. **Phase 1: 后端基础**（1-2 周）
   - 创建数据库表和迁移
   - 实现 Store 层
   - 实现 App 层核心逻辑

2. **Phase 2: API 和 WebSocket**（1 周）
   - 实现 API 端点
   - 集成 WebSocket 事件
   - 编写单元测试

3. **Phase 3: 前端 UI**（1-2 周）
   - 实现 Redux actions
   - 创建 UI 组件
   - 添加样式

4. **Phase 4: 优化和测试**（1 周）
   - 性能优化
   - 集成测试和 E2E 测试
   - Bug 修复

5. **Phase 5: 文档和发布**（几天）
   - 编写用户文档
   - 更新 API 文档
   - 准备发布说明

## 总结

### 优势
✅ **易于实现**：基于现有的 `ChannelMember.LastViewedAt` 机制扩展
✅ **性能可控**：通过索引、缓存和数据清理策略保证性能
✅ **用户体验好**：实时更新、直观的 UI 显示
✅ **可配置**：支持系统级和用户级的开关控制

### 注意事项
⚠️ **隐私考虑**：需要明确告知用户已读状态会被追踪
⚠️ **存储成本**：大型团队可能产生大量数据，需要合理的清理策略
⚠️ **性能影响**：需要在写入性能和查询性能之间找到平衡

### 可选增强功能
- 支持"仅对重要消息启用已读回执"
- 已读状态的统计分析（如消息平均阅读时间）
- 与提醒功能集成（未读消息提醒）
