# GateServer runtime map

`GateServer` is the client-facing transport/control plane. It should stay thin:
authentication/session/transport live here, while authoritative gameplay stays
in `SceneServer`.

## Top-level supervision tree

`GateServer.Application` starts:

- `GateServer.InterfaceSup`
  - service discovery / node lookup entrypoint
- `GateServer.FastLaneRegistry`
  - ticket/session registry for UDP attachment
- `GateServer.StdioInterface` (optional)
  - attached runtime inspection surface for automation
- `GateServer.TcpAcceptorSup`
  - TCP listening acceptor(s)
- `GateServer.TcpConnectionSup`
  - one `GateServer.TcpConnection` per connected client
- `GateServer.UdpAcceptorSup` (non-test env)
  - shared UDP socket worker for fast-lane packets

## Worker roles

- `worker/tcp_acceptor.ex`
  - accepts TCP sockets and hands them to connection workers
- `worker/tcp_connection.ex`
  - per-client protocol/session worker
- `worker/udp_acceptor.ex`
  - shared UDP listener and sender for movement fast-lane
- `worker/fast_lane_registry.ex`
  - ticket issuance, peer attachment, idle cleanup

## Protocol layering

- `codec.ex` is the translation seam between binary payloads and structured
  tuples
- `tcp_connection.ex` owns dispatch/state machine logic
- `udp_acceptor.ex` owns the shared UDP socket but delegates authority to the
  connection and scene layers
- `stdio_interface.ex` is strictly observational/control-adjacent; it should not
  become a second source of runtime truth
