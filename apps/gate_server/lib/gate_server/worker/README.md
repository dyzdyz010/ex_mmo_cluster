# Gate worker runtime map

This directory contains the runtime workers that make up the gate transport
layer.

## Key workers

- `interface.ex`
  - service discovery / downstream node lookup
- `tcp_acceptor.ex`
  - accepts new TCP sockets
- `tcp_connection.ex`
  - per-client protocol/session worker
- `udp_acceptor.ex`
  - shared UDP fast-lane listener/sender
- `fast_lane_registry.ex`
  - ticket/session registry for UDP attachment

## Design rule

Workers here should stay transport/session focused. Authoritative gameplay state
belongs in `SceneServer`, not in gate workers.
