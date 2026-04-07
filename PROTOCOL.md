# Wire Protocol Specification

## Overview

All client-server communication uses TCP with a custom binary protocol. No protobuf.

## Framing

Every TCP message is length-prefixed with a 4-byte big-endian header, handled automatically by Erlang's `{packet, 4}` socket option.

```
┌──────────────────┬─────────────────────────┐
│ length (4 bytes) │ body (variable length)   │
│ big-endian u32   │ msg_type (1) + payload   │
└──────────────────┴─────────────────────────┘
```

The **length** field is the byte count of `body` only (not including itself). Clients must prepend this header when sending; the server prepends it automatically.

## Message Format

```
body = <<msg_type::8, payload::binary>>
```

- `msg_type`: 1 byte, identifies the message
- `payload`: message-specific binary fields

## Data Types

| Type | Size | Encoding |
|------|------|----------|
| `u8` | 1 byte | unsigned big-endian |
| `u16` | 2 bytes | unsigned big-endian |
| `i64` | 8 bytes | signed big-endian |
| `u64` | 8 bytes | unsigned big-endian |
| `f64` | 8 bytes | IEEE 754 double, big-endian |
| `string` | 2 + N bytes | `<<length::16-big, data::binary-size(length)>>` |
| `vec3` | 24 bytes | `<<x::f64, y::f64, z::f64>>` |

All vectors use **double precision (f64)** for consistency with the internal physics engine (Rapier3D via Rust NIF).

---

## Client → Server Messages (0x01–0x7F)

### 0x01 — Movement

Sent every frame while the player is moving.

```
<<0x01, cid::i64, timestamp::u64, location::vec3, velocity::vec3, acceleration::vec3>>
```

| Field | Type | Description |
|-------|------|-------------|
| cid | i64 | Character ID |
| timestamp | u64 | Client timestamp (ms since epoch) |
| location | vec3 | Current position (x, y, z) |
| velocity | vec3 | Current velocity |
| acceleration | vec3 | Current acceleration |

**Total size**: 89 bytes (1 + 8 + 8 + 24 + 24 + 24)

### 0x02 — EnterScene

Request to enter a game scene.

```
<<0x02, cid::i64>>
```

| Field | Type | Description |
|-------|------|-------------|
| cid | i64 | Character ID to enter scene with |

**Total size**: 9 bytes

### 0x03 — TimeSync

Request time synchronization with the server.

```
<<0x03>>
```

No fields. **Total size**: 1 byte

### 0x04 — Heartbeat

Keep-alive ping.

```
<<0x04, timestamp::u64>>
```

| Field | Type | Description |
|-------|------|-------------|
| timestamp | u64 | Client timestamp (ms) |

**Total size**: 9 bytes

### 0x05 — AuthRequest

Authenticate with username and token.

```
<<0x05, username::string, code::string>>
```

| Field | Type | Description |
|-------|------|-------------|
| username | string | Player username (UTF-8) |
| code | string | Auth token/code |

**Total size**: variable (5 + username_len + code_len)

---

## Server → Client Messages (0x80–0xFF)

### 0x80 — Result

Generic operation result. May include additional payload depending on context.

**Simple result (ok/error):**
```
<<0x80, packet_id::i64, status::u8>>
```

**Movement ack (with player position):**
```
<<0x80, packet_id::i64, status::u8, cid::i64, location::vec3>>
```

| Field | Type | Description |
|-------|------|-------------|
| packet_id | i64 | Correlation ID |
| status | u8 | 0x00 = ok, 0x01 = error |
| cid | i64 | (optional) Character ID |
| location | vec3 | (optional) Current position |

### 0x81 — PlayerEnter (Broadcast)

Another player entered your area of interest.

```
<<0x81, cid::i64, location::vec3>>
```

**Total size**: 33 bytes

### 0x82 — PlayerLeave (Broadcast)

A player left your area of interest.

```
<<0x82, cid::i64>>
```

**Total size**: 9 bytes

### 0x83 — PlayerMove (Broadcast)

A nearby player moved.

```
<<0x83, cid::i64, location::vec3>>
```

**Total size**: 33 bytes

### 0x84 — EnterSceneResult

Response to EnterScene request.

**Success:**
```
<<0x84, packet_id::i64, 0x00, location::vec3>>
```

**Error:**
```
<<0x84, packet_id::i64, 0x01>>
```

### 0x85 — TimeSyncReply

Response to TimeSync request.

```
<<0x85>>
```

**Total size**: 1 byte

### 0x86 — HeartbeatReply

Response to Heartbeat.

```
<<0x86, timestamp::u64>>
```

| Field | Type | Description |
|-------|------|-------------|
| timestamp | u64 | Server timestamp (ms) |

**Total size**: 9 bytes

---

## Message Size Summary

| Message | Direction | Fixed Size | Notes |
|---------|-----------|-----------|-------|
| Movement | C→S | 89 bytes | Hot path, highest frequency |
| EnterScene | C→S | 9 bytes | |
| TimeSync | C→S | 1 byte | |
| Heartbeat | C→S | 9 bytes | |
| AuthRequest | C→S | variable | |
| PlayerEnter | S→C | 33 bytes | Broadcast |
| PlayerLeave | S→C | 9 bytes | Broadcast |
| PlayerMove | S→C | 33 bytes | Broadcast, high frequency |
| EnterSceneResult | S→C | 10 or 34 | |
| TimeSyncReply | S→C | 1 byte | |
| HeartbeatReply | S→C | 9 bytes | |

## Implementation

- **Server codec**: `apps/gate_server/lib/gate_server/codec.ex`
- **TCP framing**: `{packet, 4}` on `gen_tcp` socket (automatic length prefix)
- **Byte order**: All fields big-endian (network byte order)
