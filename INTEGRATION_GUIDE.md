# 读回执功能集成指南

本指南说明如何将读回执功能集成到 Mattermost 的现有组件中。

## 前端集成步骤

### 1. 注册 Reducer

在 `webapp/channels/src/reducers/views/index.ts` 中添加：

```typescript
import readReceipts from './read_receipts';

export default combineReducers({
    // ... 其他 reducers
    readReceipts,
});
```

### 2. 注册 WebSocket 事件

在 `webapp/channels/src/actions/websocket_actions.tsx` 中添加：

```typescript
import {handleReadCursorAdvancedEvent} from './websocket_actions/read_receipts';

// 在 handleEvent 函数中添加
case 'read_cursor_advanced':
    handleReadCursorAdvancedEvent(msg)(dispatch, getState);
    break;
```

### 3. 集成到 Post 组件

在 `webapp/channels/src/components/post_view/post/post.tsx` 中：

```typescript
import PostReadIndicator from 'components/post_view/post_read_indicator';
import PostReadReceiptsModal from 'components/post_view/post_read_receipts_modal';

class Post extends React.PureComponent {
    state = {
        showReadReceiptsModal: false,
    };

    handleShowReadReceipts = () => {
        this.setState({showReadReceiptsModal: true});
    };

    handleHideReadReceipts = () => {
        this.setState({showReadReceiptsModal: false});
    };

    render() {
        const {post} = this.props;
        
        return (
            <div className='post'>
                {/* 现有的 post 内容 */}
                
                {/* 添加读回执指示器 */}
                <PostReadIndicator
                    postId={post.id}
                    readCount={this.props.readCount}
                    onClick={this.handleShowReadReceipts}
                />
                
                {/* 添加读回执 Modal */}
                <PostReadReceiptsModal
                    show={this.state.showReadReceiptsModal}
                    onHide={this.handleHideReadReceipts}
                    postId={post.id}
                    channelId={post.channel_id}
                    readers={this.props.readers}
                    totalCount={this.props.readCount}
                    isLoading={this.props.isLoadingReaders}
                />
            </div>
        );
    }
}
```

### 4. 连接 Redux State

创建 `webapp/channels/src/components/post_view/post/post_with_read_receipts.tsx`：

```typescript
import {connect} from 'react-redux';
import {bindActionCreators} from 'redux';

import {getReadCursor} from 'actions/read_receipts';

import type {GlobalState} from 'types/store';

import Post from './post';

function mapStateToProps(state: GlobalState, ownProps: any) {
    const {post} = ownProps;
    const channelCursors = state.views.readReceipts.cursors[post.channel_id] || {};
    
    // 计算已读人数（简化版本）
    const readCount = Object.values(channelCursors).filter(
        (cursor: any) => cursor.last_post_seq >= post.create_at
    ).length;

    return {
        ...ownProps,
        readCount,
        readers: [], // 需要从 ReadIndexService 获取
        isLoadingReaders: false,
    };
}

function mapDispatchToProps(dispatch: any) {
    return {
        actions: bindActionCreators({
            getReadCursor,
        }, dispatch),
    };
}

export default connect(mapStateToProps, mapDispatchToProps)(Post);
```

### 5. 自动推进读游标

在 `webapp/channels/src/components/channel_view/channel_view.tsx` 中：

```typescript
import {advanceReadCursor} from 'actions/read_receipts';

class ChannelView extends React.PureComponent {
    componentDidMount() {
        // 当用户进入频道时，自动推进读游标
        const {channelId, actions} = this.props;
        
        // 获取最新消息的时间戳
        const latestPost = this.getLatestPost();
        if (latestPost) {
            actions.advanceReadCursor(channelId, latestPost.create_at);
        }
    }
    
    // ...
}
```

## 后端集成（已完成）

后端集成已经自动完成：

1. ✅ 数据库迁移会在服务器启动时自动执行
2. ✅ API 端点已注册到路由
3. ✅ ViewChannel API 会自动推进读游标
4. ✅ WebSocket 事件会自动发送

## 配置选项

### Server 配置

在 `config.json` 中添加（可选）：

```json
{
  "ReadReceiptsSettings": {
    "Enable": true,
    "MaxChannelSize": 2000,
    "ReadIndexServiceURL": "http://localhost:8066"
  }
}
```

### 大群降级策略

根据频道大小自动降级：

- **≤8 人**: 显示完整用户列表 + 头像
- **9-256 人**: 显示计数 + 前 20 人
- **257-2000 人**: 仅显示计数 + 点击查看前 50 人
- **>2000 人**: 仅显示计数

实现示例：

```typescript
function getReadReceiptsConfig(channelMemberCount: number) {
    if (channelMemberCount <= 8) {
        return {showAvatars: true, showList: true, limit: 100};
    } else if (channelMemberCount <= 256) {
        return {showAvatars: false, showList: true, limit: 20};
    } else if (channelMemberCount <= 2000) {
        return {showAvatars: false, showList: false, limit: 50};
    } else {
        return {showAvatars: false, showList: false, limit: 0};
    }
}
```

## 性能优化

### 1. 客户端防抖

```typescript
import debounce from 'lodash/debounce';

class ChannelView extends React.PureComponent {
    // 防抖 5 秒
    debouncedAdvanceReadCursor = debounce((channelId, seq) => {
        this.props.actions.advanceReadCursor(channelId, seq);
    }, 5000);
    
    handleScroll = () => {
        const latestVisiblePost = this.getLatestVisiblePost();
        if (latestVisiblePost) {
            this.debouncedAdvanceReadCursor(
                this.props.channelId,
                latestVisiblePost.create_at
            );
        }
    };
}
```

### 2. 批量查询

```typescript
// 批量获取多条消息的已读计数
async function fetchReadCountsForPosts(channelId: string, postIds: string[]) {
    const seqs = postIds.map(id => getPostSeq(id));
    const response = await fetch('http://localhost:8066/read-counts', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({channel_id: channelId, seqs}),
    });
    return response.json();
}
```

### 3. 缓存策略

```typescript
// 使用 Redux 缓存已读计数
const readCountsCache = new Map();

function getCachedReadCount(postId: string) {
    const cached = readCountsCache.get(postId);
    if (cached && Date.now() - cached.timestamp < 30000) { // 30秒缓存
        return cached.count;
    }
    return null;
}
```

## 测试

### 单元测试示例

```typescript
import {advanceReadCursor} from 'actions/read_receipts';

describe('advanceReadCursor', () => {
    test('should dispatch READ_CURSOR_ADVANCED action', async () => {
        const dispatch = jest.fn();
        const channelId = 'channel123';
        const seq = 1700000000000;
        
        await advanceReadCursor(channelId, seq)(dispatch);
        
        expect(dispatch).toHaveBeenCalledWith({
            type: 'READ_CURSOR_ADVANCED',
            data: expect.objectContaining({
                channel_id: channelId,
                last_post_seq: seq,
            }),
        });
    });
});
```

## 故障排查

### 前端问题

1. **读回执不显示**
   - 检查 reducer 是否正确注册
   - 检查 WebSocket 连接是否正常
   - 查看浏览器控制台是否有错误

2. **计数不准确**
   - 检查 ReadIndexService 是否运行
   - 验证 Redis Stream 是否有事件
   - 检查时间戳是否正确

### 后端问题

1. **API 返回 404**
   - 确认数据库迁移已执行
   - 检查路由是否正确注册

2. **游标未更新**
   - 检查权限
   - 查看 Server 日志
   - 验证数据库连接

## 完整示例

查看 `webapp/channels/src/components/post_view/` 目录下的完整实现示例。

## 下一步

1. 根据实际需求调整 UI 样式
2. 添加更多的用户交互功能
3. 实现移动端适配
4. 添加 E2E 测试
