# Chat Domain

职责：

- 定义浏览器侧聊天意图和下行消息的最小业务类型。
- 保持客户端只能声明 `world` / `region` / `local` scope；具体频道、分区、
  chunk、半径和收件人都由服务器侧 Gate / Chat / World 派生。

边界：

- 本目录不拥有连接、投递、历史或频道权限。
- 前端不要在这里加入 `region_id`、`chunk_coord`、radius 或玩家位置作为聊天
  权威字段；这些字段属于服务器分区上下文。
- 发送入口走 `TransportPump.sendChat()`，可观察入口走 `chat:message-received`
  event bus 事件和 `window.__voxelCli.run("chat ...")`。
