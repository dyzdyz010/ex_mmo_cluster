# Chat v1 Design

## Goal

Establish a server-authoritative chat runtime that can grow into world,
region, local, system, party, and guild channels without using Scene AOI loops
as the source of chat truth.

## Ownership

- Gate owns authenticated connection state and protocol encoding.
- Chat owns session presence, channel policy, delivery planning, message IDs,
  bounded runtime history, and chat observe logs.
- World owns partition truth and should become the source for chat region/local
  presence updates.
- Scene owns hot actor simulation and may emit authoritative boundary events,
  but it does not own chat history or fan-out policy.
- DataService will own durable chat history later; it is not in the v1 hot path.

## Runtime Contract

`ChatServer.Runtime` accepts:

- `join/2`: server-side session metadata from Gate after `EnterScene`.
- `leave/2`: session cleanup when the connection closes.
- `say/2`: a validated message intent with a scope.
- `snapshot/1`: CLI/debug state.

`ChatServer.DeliveryPlan` is pure and deterministic. It supports:

- `{:world, logical_scene_id}`
- `{:region, logical_scene_id, region_id}`
- `{:local, logical_scene_id, center_chunk, radius}`
- `{:system, :all | logical_scene_id}`

The runtime maintains derived world / region / local presence indexes keyed by
server-authoritative session metadata. Message delivery uses these indexes so
region and local chat do not scan the whole session table on every message.
The original scan planner remains a deterministic fallback for isolated tests.

`ChatServer.RuntimeDirectory` is the production-shaped entry point for scene
sharding. It maps authoritative `logical_scene_id` values to shard-local
`ChatServer.Runtime` processes and keeps only routing metadata such as
`cid -> logical_scene_id`. It does not own chat recipients, history, or presence
indexes; each shard runtime remains the single truth for its logical scene. This
keeps world/region/local delivery co-located for one scene and avoids a second
membership truth before region-level scaling is needed.

## V1 Boundary

Gate keeps `0x08 ChatSay` as the backward-compatible world-channel frame.
Scoped chat uses `0x0A ChatSayScoped`, whose payload carries only
`request_id`, `scope`, and `text`. Gate resolves the concrete channel from the
connection's server-owned `partition_context` / `chat_context` through
`GateServer.ChatScope`; clients never send `region_id`, `chunk_coord`, local
radius, or location as channel authority.

The v1 `region_id` and `chunk_coord` values are session metadata fed from World
partition and server-authoritative movement boundary events. Region/local chat
therefore shares the same partition truth as voxel subscription refreshes and
does not depend on Scene AOI chat paths.

When a World partition window is available, Gate may attach server-derived
`candidate_region_ids` to local chat. This does not grant Gate or the client
chat authority: the hint only narrows Chat's presence-index lookup, and Chat
still applies exact server-side chunk-radius filtering before fan-out. Gate uses
the hint only when its `candidate_region_radius` covers the requested local
radius; otherwise it falls back to the ordinary local chunk-window plan so
cross-region nearby players are not skipped by an undersized hint.

## Browser Client Contract

The browser client exposes scoped chat through the visible chat panel and
`window.__voxelCli.run("chat <world|region|local> <text...>")`. Both entrypoints
use the same command path and encode `ChatSayScoped(0x0A)`.

Incoming `ChatMessage(0x89)` frames are decoded as typed chat messages, logged
as `chat_message_received`, delivered through `chat:message-received`, and then
rendered by the chat panel. The browser does not derive recipients or local
radius. It also does not send `region_id`, `chunk_coord`, radius, or position in
chat frames.
