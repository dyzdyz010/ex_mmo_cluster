# Bevy Client Bug Sweep (2026-04-25)

Follow-up after the restructure (`feat/bevy-client-restructure` phases 0-6).
The user reported "all implementations are broken — camera, ray hit,
view-relative movement, movement sync, prefab placement". This document
records the systematic-debugging investigation and the fixes applied.

## Investigation method

Per `superpowers:systematic-debugging` Iron Law: **no fixes without root
cause**. Tools available in this session were code reading, observe-log
analysis, headless smoke tests, and unit tests — no GUI verification.

The user memory `feedback_align_with_industry.md` says: "movement /
prediction / reconciliation 类修复先查 UE CMC / Source / Valorant 范式,
别打临时补丁堵症状". The web client at `clients/web_client/` already
implements the agreed gameplay, so it serves as the authoritative oracle
for behavior the Bevy client must match.

## Bugs found and fixed

### 1. View-relative movement was missing (foundational fix)

**Symptom**: Pressing W always walked the player along sim −Y regardless
of where the camera was pointing. Same for A/S/D — the player walked
along world axes, not camera-relative axes.

**Root cause**: `MovementSyncPlugin::sample_movement_input` stored the
raw WASD 2D vector (W = `(0, 1)`, etc.) directly in
`MovementIntent::direction`. `movement_sender` forwarded it as
`input_dir` over the wire. The server's
`movement_core::integrator::tick_grounded` treats `input_dir` as
**world-axis** horizontal velocity components
(`desired_velocity = [dir.x * speed, dir.y * speed, 0]`), so without
camera-relative rotation the player walks "north in sim space" no matter
which way the camera is facing.

**Web client reference**:
`clients/web_client/src/domain/movement/inputDirection.ts::buildMovementInputDirection`
rotates the strafe/forward 2D vector by `cameraYawRadians` before
sending. Both the camera and the input rotation use the same
`(sin(yaw), _, cos(yaw))` offset convention.

**Fix** (commit `9f3a293`):

- New pure-math helper `crate::camera::orbit::input_to_world_direction(input, yaw)`
  with 4 unit tests (W and D at yaw=0 and yaw=π/2).
- `sample_movement_input` now reads `Res<OrbitCameraState>` and rotates
  WASD via the helper before writing `MovementIntent::direction`.
- Existing tests updated to insert an `OrbitCameraState { yaw: 0.0, .. }`
  and assert `(0, -1)` for W. New ECS-level test
  `w_press_rotates_input_by_camera_yaw` proves the system glue rotates
  by the camera resource (W at yaw=π/2 → direction `(-1, 0)`).

**Stdio path is unchanged**: `ClientStdioCommand::Move { direction, .. }`
in `stdio::plugin::poll_stdio_commands` still writes `direction`
directly. Automation flows specify world-axis direction explicitly,
matching the prior contract; headless smoke tests verify this.

### 2. Default camera yaw differed from web client by ~88°

**Symptom**: First impression of the Bevy client felt off — the camera
spawned in a different quadrant than the web client.

**Root cause**: `OrbitCameraState::default` used `yaw = -0.75` (≈ −43°)
while web client (`scene.ts`) uses `Math.PI * 0.25` ≈ +45°. Both clients
share the same `(sin(yaw)*cos(pitch), sin(pitch), cos(yaw)*cos(pitch))`
offset formula, so opposite-sign yaw places the camera in opposite
quadrants.

**Fix** (commit `82fb11d`): default `yaw = π/4`, `pitch = 0.58` to match
web client byte-for-byte.

## Bugs investigated but not (yet) reproduced

### Camera mouse drag / pitch / zoom

Compared `update_orbit_camera` against web client `scene.ts`:

- Sensitivity constants identical (`YAW = 0.005`, `PITCH = 0.004`).
- Pitch clamps identical (`MIN = 0.2`, `MAX = 1.15`).
- Distance clamps identical (`MIN = 180`, `MAX = 620`).
- Mouse delta sign convention identical (`yaw -= dx*sens`, `pitch += dy*sens`).
- Wheel zoom direction identical (positive wheel = zoom in).
- Wheel sensitivity differs (Bevy 28.0/event vs web 0.35/pixel) but
  practically equivalent because Bevy `MouseWheel.y` is one-per-line
  while DOM `WheelEvent.deltaY` is ~100 px/line.

No additional changes made — the camera math itself appears correct.
After fixes #1 and #2 the camera-relative input feel should match the
web client. Any remaining "camera weirdness" needs GUI repro from the
user.

### Screen-center ray hit

Reviewed `VoxelPlugin::update_voxel_selection` →
`crate::app::ray_from_viewport` (re-implemented in phase 4.6, audited
against original on master and corrected `direction.into()` → `.as_vec3()`,
`< EPSILON` → `<= EPSILON`) → `find_voxel_selection_from_ray` (verbatim
move). Worked through the math: with default camera at
`(243, 334, 243)`, target at `(0, 110, 0)`, the screen-center ray heads
into the voxel showcase grid and intersects the cubes around the actor.

Existing test `voxel_3d_ray_selects_hit_face_and_adjacent_macro` covers
the core AABB-ray intersection logic.

The user-reported "ray hit doesn't work" symptom may have been a
downstream effect of #1 (player visually facing the wrong way relative
to the cubes the user expected to hit). Re-test after #1 + #2.

### Movement sync / prediction

Reviewed `advance_local_render_prediction`, `movement_sender`,
`should_send_stop_sync`, `movement_flags_for_intent`,
`net::runtime::handle_command::MoveInputSample`, and
`net::runtime::handle_server_message::MovementAck`.

The pattern matches Unreal CMC / Source-style "anchor + partial step"
prediction with smoothed correction (`pending_correction` decays
exponentially via `smoothing_rate_hz`). The 8 net runtime tests in
`net::runtime::tests` cover stale-ack rejection, fast-lane fallback,
re-bootstrap backoff, and ack/transport handling. No anomaly spotted in
code reading.

The user-reported "movement sync" symptom may have been "player walks
the wrong direction → looks like server fights client". Re-test after
#1 + #2.

### Prefab placement / boundary snap

`VoxelPlugin::handle_voxel_input` consumes the screen-center selection
and calls `voxel_world.place_prefab_boundary_snap` with macro fallback.
The 7 voxel parity tests
(`tests/voxel_parity.rs::boundary_snap_uses_micro_overlap_and_contact_rules`,
`builtin_prefabs_match_web_resolution_and_smoke_counts`, etc.) lock the
algorithm against the web client. No anomaly in code reading.

Re-test after #1 + #2 — the user-reported "prefab placement broken"
symptom is most likely "ray hit pointed to the wrong cube" cascading
from the foundational view-relative bug.

## Re-test checklist (for the user, with GUI)

Recommended order so we can rule each item out quickly:

1. **Movement direction**: spawn into the showcase grid, press W/A/S/D
   one at a time. The actor should walk in the direction the camera is
   pointing for W, and rotate the meaning by 90° per yaw quarter-turn
   for A/D. Pressing W then dragging the camera 90° to the right should
   leave the actor still walking in the camera's new forward direction.
2. **Camera orbit**: drag LMB or MMB. Yaw and pitch should track mouse
   delta with the standard "drag right = world rotates left" feel.
   Ctrl+wheel zooms in (toward the player) or out.
3. **Screen-center ray**: with cubes visible, the center of the screen
   should highlight the closest cube the camera is looking at. Left-click
   or G breaks; right-click or F places (material at adjacent macro,
   prefab via boundary snap).
4. **Movement sync**: walk in a circle. The actor should not snap or
   slide visibly after key release — the
   `releasing_all_keys_zeroes_intent_immediately` regression test
   already covers the slide/auto-turn case in unit form.
5. **Prefab placement**: Hotbar 5/6/7 are sphere/cylinder/stairs.
   Ctrl+wheel adjusts hotbar; right-click on a face places. Boundary
   snap should preview a micro-wire outline; if no contact, fall back
   to a macro placement preview.

If any item still feels broken, follow up with a specific repro: which
hotbar item, which keys / mouse pattern, what the observe log
(`BEVY_CLIENT_OBSERVE_LOG=...`) shows under the `voxel`, `input`, and
`network` namespaces.

## Files touched in this sweep

- `clients/bevy_client/src/camera/orbit.rs` — `input_to_world_direction`
  helper + 4 unit tests; default yaw / pitch alignment.
- `clients/bevy_client/src/movement/plugin.rs` — `sample_movement_input`
  rotates WASD by camera yaw; tests updated; new `w_press_rotates_input_by_camera_yaw`
  test.
- `docs/docs/20-archive/client/2026-04-25-bevy-client-bug-sweep.md` — this
  document.

Restructure design context:
`docs/docs/20-archive/client/2026-04-25-bevy-client-restructure-design.md`.
