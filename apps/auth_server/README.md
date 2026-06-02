# AuthServer

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:20000`](http://localhost:20000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Browser game WebSocket bridge

`/ingame/ws` bridges browser clients to `GateServer.WsConnection`. The bridge
does not treat every downstream packet as equal:

- control, result, heartbeat, and TimeSync frames are pushed immediately;
- movement hot-path frames (`PlayerMove` and `MovementAck`) use a bounded FIFO
  realtime lane, preserving normal interpolation samples while dropping the
  oldest frames only when the realtime backlog exceeds
  `AUTH_GAME_WS_REALTIME_MAX_QUEUE`;
- field-region snapshots use a latest-only visual lane keyed by region;
- voxel chunk snapshots and deltas use a paced bulk lane.

The pacing knobs are environment variables:

- `AUTH_GAME_WS_BULK_BYTES_PER_SEC`
- `AUTH_GAME_WS_BULK_DRAIN_INTERVAL_MS`
- `AUTH_GAME_WS_REALTIME_DRAIN_INTERVAL_MS`
- `AUTH_GAME_WS_REALTIME_MAX_QUEUE`
- `AUTH_GAME_WS_VISUAL_DRAIN_INTERVAL_MS`

This keeps browser movement responsive when large voxel snapshots share the
same WebSocket with movement traffic. The supervised browser movement smoke can
exercise this path with `BROWSER_MOVEMENT_NET_BYTES_PER_SEC`.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
