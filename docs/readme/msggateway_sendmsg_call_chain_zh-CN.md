# MsgGateway -> SendMsg 调用链笔记（WS -> RPC）

## 目标
当客户端通过 WebSocket 发送 `WSSendMsg` 请求时，服务端如何一步步把请求“送到” `openim-rpc-msg`（也就是最终会调用 `msgClient.MsgClient.SendMsg(...)`）——本页按代码实际调用路径整理。

## 相关术语/符号
- `openim-msggateway`：WebSocket 长连接网关服务（负责收消息、鉴权、协议解析、把请求转成内部 RPC）。
- `WSSendMsg`：网关协议里的“发送消息”请求类型（在 `ReqIdentifier` 字段上区分）。
- `MessageHandler`：`WsServer` 注入的消息处理器抽象；在本链路里实现类是 `GrpcHandler`。
- `msgClient.MsgClient.SendMsg`：最终调用 `openim-rpc-msg` 的 gRPC 方法（protobuf 生成的 client）。

## 调用链（细到 SendMsg 调用）

1. WebSocket 升级 + 创建 Client
   - 入口：`internal/msggateway/ws_server.go` -> `wsHandler(w, r)`
   - 关键动作：
     - `ws.authClient.ParseToken(...)` 鉴权
     - `ws.websocket.Upgrade(...)` 升级为 websocket
     - 创建 `client := new(Client)`
     - `client.ResetClient(..., ws)` 让该连接持有 `longConnServer`（也就是 `WsServer`）
     - `go client.readMessage()`

2. 从 websocket 持续读取帧，并路由到不同请求处理器
   - 位置：`internal/msggateway/client.go` -> `(*Client).readMessage()`
   - 再进入：`(*Client).handleMessage(message []byte)`
   - 关键动作：
     - `c.Encoder.Decode(message, binaryReq)` 解析出网关协议结构 `binaryReq`
     - 根据 `binaryReq.ReqIdentifier` 做 `switch`

3. 命中 `WSSendMsg`：调用 `longConnServer.SendMessage(...)`
   - 位置：`internal/msggateway/client.go` -> `(*Client).handleMessage(...)`
   - 分支：`case WSSendMsg:`
   - 关键调用：
     - `resp, messageErr = c.longConnServer.SendMessage(ctx, binaryReq)`

4. `SendMessage` 的真正实现来自注入的 `MessageHandler`（GrpcHandler）
   - 依赖注入点 1：`internal/msggateway/ws_server.go` -> `(*WsServer).SetDiscoveryRegistry(...)`
   - 依赖注入点 2：`internal/msggateway/message_handler.go` -> `NewGrpcHandler(...)`
   - 注入逻辑（核心就是把 Msg/Push 的 gRPC client 注入到 `GrpcHandler`）：
     - `ws.MessageHandler = NewGrpcHandler(ws.validate, rpcli.NewMsgClient(msgConn), rpcli.NewPushMsgServiceClient(pushConn))`

5. `GrpcHandler.SendMessage(...)` 中调用 `msgClient.MsgClient.SendMsg(...)`
   - 位置：`internal/msggateway/message_handler.go` -> `(*GrpcHandler).SendMessage(ctx, data *Req)`
   - 关键步骤：
     - `proto.Unmarshal(data.Data, &msgData)`：把网关请求里的消息内容反序列化
     - `g.validate.Struct(&msgData)`：校验
     - 构造请求：`req := msg.SendMsgReq{ MsgData: &msgData }`
     - 最关键调用：
       - `resp, err := g.msgClient.MsgClient.SendMsg(ctx, &req)`

6. 返回值被封装回网关协议，并通过 websocket 写回客户端
   - 回到：`internal/msggateway/client.go`
   - 关键动作：
     - `c.replyMessage(ctx, binaryReq, messageErr, resp)`
     - `c.writeBinaryMsg(...)` 把 `Resp` 写回 websocket

## 代码定位清单（建议按顺序读）
1. `internal/msggateway/ws_server.go`
   - `wsHandler(...)`（websocket 升级与创建连接）
   - `SetDiscoveryRegistry(...)`（注入 Msg/Push/Auth/User 等 client，设置 `MessageHandler`）
2. `internal/msggateway/client.go`
   - `readMessage()`
   - `handleMessage(...)`（`WSSendMsg` 分支会走 `longConnServer.SendMessage(...)`）
3. `internal/msggateway/message_handler.go`
   - `NewGrpcHandler(...)`
   - `SendMessage(...)`（最终调用 `msgClient.MsgClient.SendMsg(...)`）

## 下一步（如果你要继续追到 openim-rpc-msg 内部）
你可以继续从：
`g.msgClient.MsgClient.SendMsg(...)`
跳到 `open-im-server/internal/rpc/msg/...` 的对应 gRPC server 实现（通常是 `SendMsg()` handler），然后观察它：
- 做消息校验/处理（好友、黑名单、免打扰等）
- 把消息写入 Kafka/Redis/Mongo 等持久化或转发链路

## 2. openim-rpc-msg：SendMsg gRPC Handler 内部流程

当网关里的 `GrpcHandler.SendMessage()` 调用 `msgClient.MsgClient.SendMsg(ctx, &req)` 后，会落到：
- `open-im-server/internal/rpc/msg/server.go`：`msg.RegisterMsgServer(server, s)` 完成注册
- `open-im-server/internal/rpc/msg/send.go`：`(*msgServer).SendMsg(ctx, req)` 才是核心 handler

下面按代码路径拆开看。

### 2.1 `(*msgServer).SendMsg()`（总入口）
- 入口：`open-im-server/internal/rpc/msg/send.go: SendMsg`
- 关键步骤：
  - `req.MsgData == nil`：参数校验
  - `authverify.CheckAccess(ctx, req.MsgData.SendID)`：访问权限校验
  - 调用内部真正处理：`resp, err := m.sendMsg(ctx, req, before)`
  - 如果 webhook 修改过内容（`before` 和 `req.MsgData` 不相等），会把 `resp.Modify = req.MsgData`

### 2.2 `sendMsg()`：根据 SessionType 分发逻辑
- 入口：`open-im-server/internal/rpc/msg/send.go: func (m *msgServer) sendMsg(...)`
- 关键步骤：
  - `m.encapsulateMsgData(req.MsgData)`：补齐基础字段（`ServerMsgID`、`SendTime` 等），并根据 `ContentType` 调整 `Options` 开关
  - `switch req.MsgData.SessionType`：
    - 单聊：`m.sendMsgSingleChat(...)`
    - 群聊：`m.sendMsgGroupChat(...)`
    - 通知：`m.sendMsgNotification(...)`

### 2.3 单聊：`sendMsgSingleChat`
- 文件：`open-im-server/internal/rpc/msg/send.go`
- 关键步骤（按执行顺序）：
  1. `m.messageVerification(ctx, req)`：单聊校验（黑名单/好友关系/免打扰等）
  2. `msgprocessor.IsNotificationByMsg(req.MsgData)` 判断是否通知消息
  3. 如果不是通知消息，会走免打扰/接收策略修改：
     - `m.modifyMessageByUserMessageReceiveOpt(...)`，可能返回 `isSend=false`（不发送）
  4. webhook（消息可能会被修改）：
     - `m.webhookBeforeMsgModify(...)`
  5. 写入 MQ（这是把消息“送出去”的关键一步）：
     - `m.MsgDatabase.MsgToMQ(ctx, conversationutil.GenConversationUniqueKeyForSingle(req.MsgData.SendID, req.MsgData.RecvID), req.MsgData)`
  6. after webhook + 成功响应：
     - `m.webhookAfterSendSingleMsg(...)`
     - 返回 `pbmsg.SendMsgResp{ServerMsgID, ClientMsgID, SendTime}`

### 2.4 群聊：`sendMsgGroupChat`
- 文件：`open-im-server/internal/rpc/msg/send.go`
- 关键步骤：
  1. `m.messageVerification(ctx, req)`：群聊校验（群状态、是否禁言、成员资格等）
  2. 群聊 before webhook：
     - `m.webhookBeforeSendGroupMsg(...)`
  3. 通用 before 修改 webhook：
     - `m.webhookBeforeMsgModify(...)`
  4. 写入 MQ：
     - `m.MsgDatabase.MsgToMQ(ctx, conversationutil.GenConversationUniqueKeyForGroup(req.MsgData.GroupID), req.MsgData)`
  5. `@` 信息异步更新（当 `ContentType == AtText`）：
     - `go m.setConversationAtInfo(ctx, req.MsgData)`
  6. after webhook + 成功响应：
     - `m.webhookAfterSendGroupMsg(...)`
     - 返回 `pbmsg.SendMsgResp{...}`

### 2.5 通知：`sendMsgNotification`
- 文件：`open-im-server/internal/rpc/msg/send.go`
- 关键步骤：
  - 直接 `m.MsgDatabase.MsgToMQ(ctx, GenConversationUniqueKeyForSingle(sendID, recvID), msgData)`
  - 返回包含 `ServerMsgID/ClientMsgID/SendTime`

### 2.6 校验/修改细节：`messageVerification` & `modifyMessageByUserMessageReceiveOpt`
- 文件：`open-im-server/internal/rpc/msg/verify.go`
- `messageVerification`：
  - 单聊分支里会检查：系统账号、黑名单、是否好友（取决于 `m.config.RpcConfig.FriendVerify`）等
  - 群聊分支里会检查：群是否解散/是否禁言/发送者是否在群内/发送者角色等
- `modifyMessageByUserMessageReceiveOpt`：
  - 依据用户全局接收偏好 + 会话接收偏好，决定：
    - 是否发送
    - 是否需要把 `IsOfflinePush` 等选项置为 false（即“免打扰”语义）

### 2.7 真正落 MQ：`MsgDatabase.MsgToMQ`
- 文件：`open-im-server/pkg/common/storage/controller/msg.go`
- 实现逻辑非常直接：
  - `proto.Marshal(msg2mq)` 序列化
  - `db.producer.SendMessage(ctx, key, data)`：把消息发送到 Kafka Topic（`msg.Start` 里用 `config.KafkaConfig.ToRedisTopic` 初始化 producer）

到这里，你就能看到：
- `openim-msggateway` 负责把 WS 协议翻译成网关内部请求
- `openim-rpc-msg` 的 `SendMsg()` 负责业务校验、webhook 修改、以及把消息写入 MQ（Kafka）

如果你希望我继续下一页：我可以从 `db.producer.SendMessage(...)` 对应的 Kafka Topic 入手，追到 `openim-msgtransfer`（Kafka consumer）如何把消息落 Mongo/Redis 并触发 `openim-push` 推送。

## 3. openim-msgtransfer：消费 toRedis -> 写 Redis -> 产出 toPush

上一节里，`openim-rpc-msg` 最终调用了：
- `m.MsgDatabase.MsgToMQ(...)`
- 进而调用 `producer.SendMessage(ctx, key, data)` 把消息投递到 Kafka（也就是 `config.KafkaConfig.ToRedisTopic` 对应的“下一步链路”）

### 3.1 `openim-msgtransfer` 启动：订阅 toRedis / toMongo
- 入口：`open-im-server/internal/msgtransfer/init.go: Start`
- 关键点：
  - 创建 `historyConsumer := builder.GetTopicConsumer(..., config.KafkaConfig.ToRedisTopic)`
  - `msgTransfer.historyHandler = NewOnlineHistoryRedisConsumerHandler(...)`
  - 在 `MsgTransfer.Start()` 中执行：
    - `m.historyConsumer.Subscribe(m.ctx, m.historyHandler.HandlerRedisMessage)`

### 3.2 `OnlineHistoryRedisConsumerHandler.HandlerRedisMessage`：把消息送进聚合 worker
- 文件：`open-im-server/internal/msgtransfer/online_history_msg_handler.go`
- `HandlerRedisMessage(msg mq.Message)`：
  - 调用 `och.redisMessageBatches.Put(...)`
  - worker 负责批量聚合、降低对 Redis/DB 的写放大

### 3.3 worker `do()`：分类并“写 Redis + 触发 toPushTopic”
- 文件：`open-im-server/internal/msgtransfer/online_history_msg_handler.go`
- `do()` 内主要有这几步：
  1. `parseConsumerMessages(...)`：`proto.Unmarshal(consumerMessage.Value, sdkws.MsgData)`
  2. `doSetReadSeq(...)`：如果包含 `HasReadReceipt`，会计算并写入 read seq
  3. `categorizeMessageLists(...)`：把消息分成“存储类/非存储类、通知类/非通知类”等分组
  4. `handleMsg(...)` / `handleNotification(...)`

在 `handleMsg(...)` 里可以直接看到“toPushTopic”触发点：
- `och.toPushTopic(ctx, key, conversationID, notStorageMsgList)`
- 对 `storageList` 做：
  - `BatchInsertChat2Cache(...)`（写 Redis / 更新 seq）
  - `SetHasReadSeqs(...)`
  - `MsgToMongoMQ(...)`（把消息继续投递到 toMongo）
- 最后再次触发：
  - `och.toPushTopic(ctx, key, conversationID, storageList)`

对应 `toPushTopic(...)` 的真正落点：
- `och.msgTransferDatabase.MsgToPushMQ(...)`

### 3.4 `MsgToPushMQ`：产出到 Kafka `toPushTopic`
- 文件：`open-im-server/pkg/common/storage/controller/msg_transfer.go`
- `func (db *msgTransferDatabase) MsgToPushMQ(ctx, key, conversationID, msg2mq)`
  - `proto.Marshal(&pbmsg.PushMsgDataToMQ{MsgData: msg2mq, ConversationID: conversationID})`
  - `db.producerToPush.SendMessage(ctx, key, data)`

到这里，消息就从：
`Kafka(toRedis)` -> `openim-msgtransfer` -> `Kafka(toPush)` 形成了闭环。

## 4. openim-push：消费 toPush -> 调用 openim-msggateway -> websocket 推送

### 4.1 `openim-push` 启动：订阅 toPushTopic
- 入口：`open-im-server/internal/push/push.go: Start`
- 关键点：
  - `pushConsumer := builder.GetTopicConsumer(..., config.KafkaConfig.ToPushTopic)`
  - `pushHandler := NewConsumerHandler(...)`
  - `pushConsumer.Subscribe(..., fn)`，fn 内会调用：
    - `pushHandler.HandleMs2PsChat(authverify.WithTempAdmin(msg.Context()), msg.Value())`

### 4.2 `ConsumerHandler.HandleMs2PsChat`：解析 msg + 计算在线用户
- 文件：`open-im-server/internal/push/push_handler.go`
- `HandleMs2PsChat(ctx, msg []byte)`：
  - `proto.Unmarshal(msg, &pbpush.PushMsgReq{})`
  - 根据 `SessionType`：
    - `ReadGroupChatType` -> `Push2Group`
    - 其他 -> `Push2User`

以 `Push2User` 为例：
- 会根据 `msg.Options`（例如 `IsSenderSync`）决定 `pushUserIDList`
- 然后调用：
  - `wsResults, err := c.GetConnsAndOnlinePush(ctx, msg, userIDs)`

### 4.3 `GetConnsAndOnlinePush`：在线则走 msggateway，失败则做离线推送
- 文件：`open-im-server/internal/push/push_handler.go`
- 在线/离线分流：
  - `onlineUserIDs, offlineUserIDs, err := c.onlineCache.GetUsersOnline(ctx, pushToUserIDs)`

在线推送的核心调用：
- `result, err = c.onlinePusher.GetConnsAndOnlinePush(ctx, msg, onlineUserIDs)`

在线推送的默认实现（Standalone/ETCD/K8s 之外的情况）在：
- `open-im-server/internal/push/onlinepusher.go`
- `DefaultAllNode.GetConnsAndOnlinePush(...)`：
  - `conns, _ := disCov.GetConns(...RpcService.MessageGateway)`
  - 对每个 msggateway 连接调用：
    - `msgClient.SuperGroupOnlineBatchPushOneMsg(ctx, input)`
  - 其中 `input` 是：
    - `msggateway.OnlineBatchPushOneMsgReq{MsgData: msg, PushToUserIDs: pushToUserIDs}`

### 4.4 msggateway：`SuperGroupOnlineBatchPushOneMsg` -> `client.PushMessage` -> websocket
- 文件：`open-im-server/internal/msggateway/hub_server.go`
- `func (s *Server) SuperGroupOnlineBatchPushOneMsg(ctx, req ...)`：
  - 对每个 `userID`：
    - `s.queue.PushCtx(... s.pushToUser(ctx, userID, req.MsgData) ...)`

- `pushToUser(...)` 做在线连接获取并逐个推送：
  - `clients, ok := s.LongConnServer.GetUserAllCons(userID)`
  - 对每个 `client` 调用：
    - `client.PushMessage(ctx, msgData)`

- `client.PushMessage` 在 `open-im-server/internal/msggateway/client.go`：
  - 构造 `sdkws.PushMessages`
  - `proto.Marshal(&msg)`
  - 构造网关返回 `Resp{ReqIdentifier: WSPushMsg, Data: data}`
  - `c.writeBinaryMsg(resp)` 最终通过 websocket `WriteMessage` 发给前端

到这里，你要的“到 websocket 怎么发”就完整串起来了：
`Kafka(toPush)` -> `openim-push` -> gRPC `openim-msggateway.SuperGroupOnlineBatchPushOneMsg`
-> `WsServer/Client.PushMessage` -> `websocket.WriteMessage`


