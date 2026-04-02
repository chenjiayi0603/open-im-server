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

