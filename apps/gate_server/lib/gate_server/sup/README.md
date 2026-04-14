# Gate supervisor subtrees

This directory contains the small supervisor wrappers that shape the gate
runtime tree.

## Current subtrees

- `InterfaceSup`
  - `GateServer.Interface`
- `TcpAcceptorSup`
  - `GateServer.TcpAcceptor`
- `TcpConnectionSup`
  - one `GateServer.TcpConnection` per client
- `UdpAcceptorSup`
  - `GateServer.UdpAcceptor`

`GateServer.FastLaneRegistry` is currently supervised directly by the
application root because it is a singleton registry, not a subtree.
