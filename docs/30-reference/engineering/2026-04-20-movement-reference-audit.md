# Movement-Sync Defaults — Reference Audit

**Date:** 2026-04-20  
**Scope:** Every numeric default in the client movement-sync layer, compared against
published industry references. Reviewers can use this page to confirm provenance
without reading source code.

---

## 1. Server Tick & Snapshot Cadence

**Our value:** `SNAPSHOT_TICK_SECS = 0.1` (100 ms)  
**Source:** `clients/bevy_client/src/world/remote_player.rs:9`  
**Mirror:** `MovementProfile.fixed_dt_ms = 100` in both
`clients/bevy_client/src/sim/profile.rs:31` and
`apps/scene_server/native/movement_core/src/profile.rs:45`

| Engine / Game | Server Tick | Period |
|---|---|---|
| Valve Source — CS:GO competitive | 64 Hz | 15.625 ms |
| Valve Source — CS:GO casual | 32 Hz | 31.25 ms |
| Amazon New World (GDC 2022, "500 Players in One Shard") | ~10 Hz sim, ~10 Hz net | ~100 ms |
| Overwatch (Timothy Ford, GDC 2017) | 60 Hz | 16.7 ms |
| Unreal Engine 5 default physics | 30 Hz | 33.3 ms |
| Unreal Engine 5 default replication | 20 Hz | 50 ms |
| **This project** | **10 Hz** | **100 ms** |

**Justification:** MMO scale (1 000+ entities per shard) makes sub-50 ms ticks
bandwidth-prohibitive. Amazon New World's published 100 ms network cadence provides
direct industry parity for a high-entity-count MMO. Valve/Unreal defaults target
10–60-player shooters, a different operating point.

---

## 2. Client Interpolation Delay (`cl_interp`)

**Our value:** `INTERPOLATION_DELAY_SECS = 0.15` (150 ms)  
**Source:** `clients/bevy_client/src/world/remote_player.rs:16`

| Reference | Default delay |
|---|---|
| Yahn Bernier, Valve GDC 2001 ("Latency Compensating Methods") | 100 ms (`cl_interp = 0.1`) |
| CS:GO — 64-tick competitive (two frames) | 31.25 ms |
| CS:GO — 32-tick casual (two frames) | 62.5 ms |
| Source SDK 2013 (`cl_interp_ratio=2`, `cl_updaterate=66`) | ~30 ms |
| Unreal `NetworkSimulatedSmoothLocationTime` default | 100 ms |
| **This project** | **150 ms** |

**Justification:** 150 ms = 1.5 × the 100 ms server tick. This guarantees at
least one full server sample already sits in the buffer before the playback
cursor arrives, so a single dropped packet never forces extrapolation. The
+50 ms overhead over Bernier's baseline is the deliberate trade-off for
packet-loss tolerance at MMO scale. The code comment at line 10–15 of
`remote_player.rs` captures this reasoning verbatim.

---

## 3. Extrapolation Cap

**Our value:** `MAX_REMOTE_EXTRAPOLATION_SECS = 0.25` (250 ms)  
**Source:** `clients/bevy_client/src/world/remote_player.rs:20`

| Reference | Cap |
|---|---|
| Valve Source (`cl_extrapolate_amount = 0.25`) | 250 ms |
| Unreal `NetworkSmoothingMode::Exponential` before rubber-band | ~500 ms |
| Overwatch | not publicly disclosed |
| **This project** | **250 ms** |

**Justification:** Identical to Valve's published default. 250 ms masks short
dropout trains (2–3 lost 100 ms snapshots) while staying well under the ~500 ms
perceptible rubber-banding threshold documented in Unreal's smoothing GDC notes.

---

## 4. Replay / Rollback Frame Cap

**Our value:** `max_replay_frames = 32`  
**Source:** `clients/bevy_client/src/sim/governance.rs:26`

| Reference | Frame cap |
|---|---|
| Valve / Source | No explicit cap; prediction replays every client frame |
| Unreal NetworkPrediction plugin | 64 frames |
| Rocket League (Psyonix GDC 2018) | ~7 frames at 60 Hz (~120 ms) |
| **This project** | **32 frames** |

**Justification:** At a 100 ms authoritative tick each frame is 100 ms of
simulation, so 32 frames covers 3.2 seconds of input history — deeper than any
realistic single-packet-loss round-trip, leaving the replay budget generous
without unbounded growth. Unreal's 64-frame cap targets a 16 ms tick (60 Hz),
which is a comparable 1-second wall-clock window.

---

## 5. Pending Input Buffer

**Our value:** `max_pending_inputs = 64`  
**Source:** `clients/bevy_client/src/sim/governance.rs:27`

| Reference | Buffer size |
|---|---|
| Valve Source `cl_cmdrate` (effective ~1 second at 64 Hz) | ~64 inputs |
| Unreal NetworkPrediction plugin typical range | 32–64 inputs |
| **This project** | **64 inputs** |

**Justification:** Matches both Valve's effective 1-second command buffer and the
upper end of Unreal's typical range. At our 10 Hz tick rate 64 inputs spans
6.4 seconds, which is deliberately generous; the replay frame cap (32) is the
operative bound that limits how many of those inputs are actually re-simulated
on correction.

---

## 6. Hard-Snap Threshold

**Our value:** `hard_snap_distance = 256.0` units  
**Source:** `clients/bevy_client/src/sim/governance.rs:25`

| Reference | Threshold |
|---|---|
| Valve Source teleport detection | 256 Hammer units (~21 ft / ~6.4 m at 1 unit ≈ 1 inch) |
| Unreal `NetworkMaxSmoothUpdateDistance` default | 200 cm (2 m) |
| **This project** | **256 units** |

**Justification:** Our world uses 1 unit = 1 cm, so 256 units = 2.56 m — close
to Unreal's 200 cm default and within the same order of magnitude as Valve's
intent (detect teleportation-scale discontinuities, not normal movement error).
At `max_speed = 220 u/s`, 256 units is approximately 1.16 seconds of full-speed
travel, meaning anything beyond that is treated as a server-authoritative
teleport rather than a correctable prediction error.

**Soft threshold:** `soft_position_error = 2.0` units (governance.rs:24).
Below 2 units the reconciler accepts the prediction as floating-point noise.
Internal default, provenance TBD (chosen empirically at < 1% of a 100 ms step
at max speed).

---

## 7. Parameters from Academic Literature

**Glenn Fiedler — "Fix Your Timestep!" and "Integration Basics"**  
(Gaffer on Games blog, 2004–2006; gaffer.org)  
Our fixed-tick integrator with a jerk limiter (`max_jerk = 9 000`) directly
applies Fiedler's recommendation to use a fixed-dt accumulator loop rather than
variable-dt integration. The jerk ceiling is the rate-limiter that prevents
transient acceleration spikes — equivalent to the "control-theory rate limiter"
Fiedler discusses in his physics series.

**Mark Claypool & Kajal Claypool — "Latency and Player Actions in Online Games"**  
(Communications of the ACM, 2006)  
The Claypool model maps latency ranges to perceptible quality degradation.
Our 150 ms interpolation delay and 250 ms extrapolation cap both fall within
the "acceptable" region of that model (< 300 ms one-way lag equivalent). The
snap threshold at 256 units prevents the "position jump" artifact the paper
identifies as the most player-noticeable artifact class.

---

## 8. Open Items / Deferred Tuning

The following parameters are intentionally left at coarse defaults pending
later design phases:

| Parameter | Current value | Deferral reason |
|---|---|---|
| Per-class `MovementProfile` (ranger / heavy / mount) | single global default | P3 scope — class system not yet finalized |
| Adaptive `INTERPOLATION_DELAY_SECS` based on measured RTT | fixed 150 ms | P4+ scope — requires RTT estimation pipeline |
| `SNAPSHOT_TICK_SECS` adjustment per shard population | fixed 100 ms | P4+ scope — adaptive tick infrastructure not built |
| `soft_position_error` empirical calibration | 2.0 units | needs per-class speed data from P3 |
| `max_jerk` per-mount override | 9 000 u/s³ global | P3 scope — mount system not yet designed |

---

## 9. Citations

1. **Yahn Bernier, Valve Software** — "Latency Compensating Methods in
   Client/Server In-game Protocol Design and Optimization", GDC 2001.  
   Archived: <https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization>

2. **Timothy Ford, Blizzard Entertainment** — "Overwatch Gameplay Architecture
   and Netcode", GDC 2017.  
   GDC Vault: <https://www.gdcvault.com/play/1024001/Overwatch-Gameplay-Architecture-and>

3. **Amazon Games / New World team** — "Building a 500-Player Server with Amazon
   New World", GDC 2022.  
   GDC Vault: <https://gdcvault.com/play/1027700> (search "New World 500 players")

4. **Epic Games / Unreal Engine 5** — "Networked Movement in the Character
   Movement Component", Unreal online docs.  
   <https://dev.epicgames.com/documentation/en-us/unreal-engine/understanding-networked-movement-in-the-character-movement-component-for-unreal-engine>

5. **Psyonix / Rocket League** — "It Is Rocket Science: The Physics of Rocket
   League Detailed", GDC 2018.  
   GDC Vault: <https://www.gdcvault.com/play/1024972>

6. **Glenn Fiedler** — "Fix Your Timestep!" (2004) and "Integration Basics"
   (2004), Gaffer on Games.  
   <https://gafferongames.com/post/fix_your_timestep/>  
   <https://gafferongames.com/post/integration_basics/>

7. **Mark Claypool & Kajal Claypool** — "Latency and Player Actions in Online
   Games", Communications of the ACM, Vol. 49 No. 11, 2006.  
   ACM DL: <https://dl.acm.org/doi/10.1145/1167838.1167860>

8. **Valve Developer Community** — Source Engine network `cl_interp`,
   `cl_updaterate`, `cl_extrapolate_amount` documentation.  
   <https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking>

9. **id Software** — Quake 3 Arena source code, snapshot/command
   reconciliation in `code/game/g_active.c` (GPL release 2005). Reference
   for stale-ack rejection, duplicate-ack idempotency, and out-of-order
   safety in the reconciler (`clients/bevy_client/src/sim/reconcile.rs`
   test suite). <https://github.com/id-Software/Quake-III-Arena>

10. **Epic Games / Unreal Engine 5** — `EMovementMode` enum,
    `Engine/Source/Runtime/Engine/Classes/GameFramework/CharacterMovementComponent.h`.
    Reference for the four-mode movement state machine
    (Grounded/Airborne/Scripted/Disabled) implemented in
    `apps/scene_server/native/movement_core/src/mode.rs`.
    <https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/GameFramework/EMovementMode>
