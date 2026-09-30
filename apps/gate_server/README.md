# gate_server

Voxim QUIC 网关：鉴权、会话、协议解码与转发。运行时边界见 [`lib/gate_server/README.md`](lib/gate_server/README.md)，
会话层见 [`lib/gate_server/session/README.md`](lib/gate_server/session/README.md)。

2026-09-30：Voxim 成为唯一客户端，TCP / WebSocket / UDP 快车道、旧 chunk 订阅与旧体素意图管线、旧 WS smoke 及其测试已删除。
更早的历史记录见 git 历史与 `docs/`。
