# ChatServer Runtime Boundary

`ChatServer` is the standalone MMO chat runtime. It owns chat session presence,
channel delivery policy, bounded in-memory history, and structured observe
events. It does not own movement, AOI ticks, voxel chunks, region leases, or
durable chat history.

## Ownership

- `ChatServer.Runtime`
  - Authoritative in-memory chat session table.
  - Maintains world / region / local presence indexes so hot chat fan-out does
    not scan every connected session.
  - Message validation, message IDs, bounded recent history, and recipient fan-out.
  - Refreshes `logical_scene_id` / `region_id` / `chunk_coord` from
    server-authoritative Gate partition context updates without depending on
    Scene AOI.
  - Emits `chat_session_joined`, `chat_say_received`, `chat_delivery_planned`,
    `chat_delivered`, `chat_session_presence_updated`, and `chat_rejected`.
- `ChatServer.RuntimeDirectory`
  - Lightweight logical-scene shard directory.
  - Owns only `logical_scene_id -> Runtime` and `cid -> logical_scene_id`
    routing metadata.
  - Starts shard-local `Runtime` processes under `ChatServer.RuntimeShardSup`.
  - Rejects mismatched route attempts, for example a session registered in
    scene 7 publishing to `{:world, 8}`.
  - Migrates a session between scene shards when a server-authoritative
    presence refresh changes `logical_scene_id`, preventing stale old-shard
    membership from receiving later world chat.
- `ChatServer.DeliveryPlan`
  - Pure planner for `world`, `region`, `local`, and `system` scopes.
  - Runtime delivery uses the presence-index planner; the scan planner remains
    available for small deterministic tests and fixtures.
  - Local delivery may receive server-derived candidate region IDs from Gate's
    partition context. In that mode it first uses the region presence index to
    preselect candidates, then applies exact chunk-radius filtering.
  - Uses server-side session metadata only. It must not trust client-reported
    position or subscription centers.
- `ChatServer.CliObserve`
  - File-backed structured logs for headless debugging.
- `Mix.Tasks.ChatServer.Observe`
  - CLI smoke for deterministic channel routing without a GUI.
- `Mix.Tasks.ChatServer.ShardObserve`
  - CLI smoke for logical-scene shard routing without a GUI.
- `ChatServer.Interface`
  - Optional cluster registration. It has no chat state.

## Runtime Flow

Gate registers a chat session after the server-authoritative `EnterScene`
flow succeeds. `0x08 ChatSay` remains the compatibility world-channel frame.
`0x0A ChatSayScoped` lets the client request `world`, `region`, or `local`
scope, but Gate derives the concrete channel from server-owned partition/chat
context before calling `ChatServer.RuntimeDirectory`. The directory routes by
authoritative `logical_scene_id`; the shard-local runtime plans recipients and
casts `{:chat_message, cid, username, text}` back to Gate connection processes
for encoding as `0x89 ChatMessage`.

For production-shaped routing, `RuntimeDirectory` is the supervised entry point
that maps the authoritative `logical_scene_id` to one shard-local `Runtime`.
The application does not also start a named singleton runtime by default, so
normal Gate traffic has one chat truth. The directory does not duplicate
presence indexes, message history, usernames, connection PIDs, or chunk
positions; it only keeps routing metadata and lets the shard execute the
existing world / region / local delivery plan. Explicit test and CLI callers can
pass a private runtime or directory as a `chat_runtime` server to
`GateServer.ChatAdapter` without changing the adapter into a chat state owner.
Default Gate traffic fails closed when `RuntimeDirectory` is unavailable; it
does not silently fall back to a legacy singleton runtime.

Scene no longer owns the Gate chat send path. Legacy Scene AOI chat call shapes
are kept only as rejection guards: they emit `player_chat_legacy_rejected` or
`aoi_chat_legacy_rejected` observe events and do not deliver to connection
processes or AOI subscribers. Do not expand Scene AOI into the MMO world-chat
architecture.

## Partition Boundary

Current local/region routing uses session metadata supplied by server-side
session registration and subsequent Gate partition-context refreshes.
`GateServer.PartitionContext` derives `region_id` and `chunk_coord` from a
World partition window plus server-authoritative movement position, then Gate
refreshes chat presence through `ChatServer.RuntimeDirectory`; the selected
shard-local `Runtime` updates its own presence indexes. Do not make the client
invent region semantics, and do not route chat through Scene AOI.

When a Gate partition context carries `candidate_region_ids`, scoped local chat
may pass them to `ChatServer.DeliveryPlan` as a server-derived preselection hint.
Gate uses the hint only when its `candidate_region_radius` covers the requested
local radius; otherwise it falls back to the ordinary local chunk-window plan so
nearby cross-region recipients are not silently skipped. This is an optimization
boundary only: Chat still filters recipients by exact server-side `chunk_coord`
radius, and the client still sends only scope/text.

## CLI Smoke

```bat
cmd /c mix.bat chat_server.observe --logical-scene-id 1 --channel region --text hello
cmd /c mix.bat chat_server.observe --logical-scene-id 1 --channel local --center 0,0,0 --radius 4 --candidate-regions 10 --text hello
cmd /c mix.bat chat_server.shard_observe --logical-scene-id 7 --other-logical-scene-id 8 --channel world --text hello
cmd /c mix.bat gate_server.chat_scope_observe --logical-scene-id 1 --scope region --text hello
```

By default these tasks write `.demo/observe/*.log` and print compact summaries
containing `recipient_count`, `skipped_count`, and `plan_source`. The shard
smoke also prints `shard_key`, `route_target`, and `shard_count`, proving that a
world chat message entered the server-selected logical-scene shard instead of a
global singleton.
`plan_source=presence_index` confirms the hot runtime path used the membership
indexes.
