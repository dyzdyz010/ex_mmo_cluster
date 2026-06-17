//! Debris effect Bevy adapter (C2): wires the pure [`DebrisSimulation`] into the
//! running app so object destruction actually produces on-screen particles.
//!
//! Flow (mirrors the established Field/Chunk adapter pattern — pure sim + thin
//! ECS shell):
//!   1. The authority surfaces `ObjectStateEvent`s (object destroyed /
//!      part-destroyed / damaged, with the affected chunks) from the 0x6C stream.
//!   2. `spawn_debris_from_object_state` (Logic, after ingest) turns each event
//!      into a burst: maps `state_flags` → [`DebrisKind`], the affected chunks →
//!      spawn points (chunk centers, macro units), and calls `sim.spawn`.
//!   3. `advance_and_render_debris` (Render) integrates the sim each frame and
//!      syncs a pooled set of small cube entities to `sim.live_particles()`,
//!      scaling macro-unit positions by the macro render size.
//!
//! The simulation is the assertable half (Layer-1); the entity sync is the GPU
//! half (its pixel result is Layer-3). Randomness is a small deterministic
//! xorshift wrapped as the injected `FnMut() -> f32` the pure sim expects.

use bevy::prelude::*;

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority_plugin::VoxelAuthority;
use crate::voxel::chunk_render::MACRO_RENDER_SIZE;
use crate::voxel::debris::{
    DEFAULT_PARTICLE_SIZE_M, DebrisKind, DebrisSimulation, DebrisSpawnPoint,
};

/// Server `PartState` flag bits (mirror `SceneServer.Voxel.PartState`): note
/// `destroyed` is 0x02 and `part_destroyed` is 0x04 (NOT the other way round);
/// a fully destroyed object carries `damaged | destroyed` = 0x03.
const FLAG_DAMAGED: u32 = 0x01;
const FLAG_DESTROYED: u32 = 0x02;
const FLAG_PART_DESTROYED: u32 = 0x04;

/// Macro cells per chunk edge (mirrors the server chunk size); a chunk center is
/// `coord * 16 + 8` in macro units.
const CHUNK_SIZE_MACRO: i32 = 16;

/// Resource: the pure debris sim plus the PRNG state feeding its injected random.
#[derive(Resource)]
pub struct DebrisEffect {
    sim: DebrisSimulation,
    rng_state: u64,
}

impl Default for DebrisEffect {
    fn default() -> Self {
        Self {
            sim: DebrisSimulation::new(),
            // Non-zero xorshift seed (0 would make xorshift stick at 0).
            rng_state: 0x2545_F491_4F6C_DD1D,
        }
    }
}

/// Shared cube mesh + brown material for all debris particles (one draw setup).
#[derive(Resource)]
pub struct DebrisRenderAssets {
    mesh: Handle<Mesh>,
    material: Handle<StandardMaterial>,
}

/// Pool of live debris cube entities; index-aligned with `live_particles()`.
#[derive(Resource, Default)]
pub struct DebrisEntities(Vec<Entity>);

/// Marker for a debris cube entity (so the sync query is scoped to them).
#[derive(Component)]
pub struct DebrisParticleVisual;

pub struct DebrisEffectPlugin;

impl Plugin for DebrisEffectPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<DebrisEffect>()
            .init_resource::<DebrisEntities>()
            .add_systems(Startup, setup_debris_assets)
            // Spawn from object-state events in Logic (alongside ingest); integrate
            // + sync entities in Render. Logic runs before Render each frame, so a
            // burst spawned this frame is visible the same frame.
            .add_systems(
                Update,
                spawn_debris_from_object_state
                    .in_set(ClientSet::Logic)
                    .run_if(in_state(AppState::Game)),
            )
            .add_systems(
                Update,
                advance_and_render_debris
                    .in_set(ClientSet::Render)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

fn setup_debris_assets(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
) {
    // 0.05 m particle * macro render size (100) = 5 render units, matching the
    // web debrisRenderer's DEFAULT_PARTICLE_SIZE_WORLD.
    let edge = DEFAULT_PARTICLE_SIZE_M * MACRO_RENDER_SIZE;
    let mesh = meshes.add(Cuboid::from_length(edge));
    let material = materials.add(StandardMaterial {
        base_color: Color::srgb(0.55, 0.27, 0.075), // brown (#8B4513-ish)
        perceptual_roughness: 0.85,
        ..default()
    });
    commands.insert_resource(DebrisRenderAssets { mesh, material });
}

/// Maps the latest `state_flags` to the burst kind, or `None` if no
/// destruction-feedback bit is set (so we don't spawn debris for a no-op event).
fn debris_kind(state_flags: u32) -> Option<DebrisKind> {
    if state_flags & FLAG_DESTROYED != 0 {
        Some(DebrisKind::Destroyed)
    } else if state_flags & FLAG_PART_DESTROYED != 0 {
        Some(DebrisKind::PartDestroyed)
    } else if state_flags & FLAG_DAMAGED != 0 {
        Some(DebrisKind::Damaged)
    } else {
        None
    }
}

/// The center of a chunk in macro units (the renderer scales by macro size).
fn chunk_center_macro(coord: [i32; 3]) -> DebrisSpawnPoint {
    let half = CHUNK_SIZE_MACRO / 2;
    DebrisSpawnPoint {
        x: (coord[0] * CHUNK_SIZE_MACRO + half) as f32,
        y: (coord[1] * CHUNK_SIZE_MACRO + half) as f32,
        z: (coord[2] * CHUNK_SIZE_MACRO + half) as f32,
    }
}

/// Advances the PRNG (xorshift64) and returns a value in `[0, 1)`.
fn next_unit(state: &mut u64) -> f32 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    // Top 24 bits → [0, 1) (24 = f32 mantissa precision).
    ((x >> 40) as f32) / ((1u64 << 24) as f32)
}

fn spawn_debris_from_object_state(
    mut authority: ResMut<VoxelAuthority>,
    mut effect: ResMut<DebrisEffect>,
) {
    let events = authority.take_object_state_events();
    if events.is_empty() {
        return;
    }
    // Split-borrow so the rng closure (borrows rng_state) and sim coexist.
    let DebrisEffect { sim, rng_state } = &mut *effect;
    for event in events {
        let Some(kind) = debris_kind(event.state_flags) else {
            continue;
        };
        let points: Vec<DebrisSpawnPoint> = event
            .affected_chunks
            .iter()
            .map(|c| chunk_center_macro(*c))
            .collect();
        if points.is_empty() {
            continue;
        }
        let mut rng = || next_unit(rng_state);
        sim.spawn(&points, kind, &mut rng);
    }
}

fn advance_and_render_debris(
    mut commands: Commands,
    time: Res<Time>,
    mut effect: ResMut<DebrisEffect>,
    mut entities: ResMut<DebrisEntities>,
    assets: Option<Res<DebrisRenderAssets>>,
    mut transforms: Query<&mut Transform, With<DebrisParticleVisual>>,
) {
    let Some(assets) = assets else {
        return; // assets not ready yet (first frame ordering)
    };

    effect.sim.update(time.delta_secs() * 1000.0);
    let live = effect.sim.live_particles();

    // Index-aligned pool sync: update existing entities in place, spawn new ones
    // (with their initial transform, so no first-frame lag), despawn the surplus.
    for (i, p) in live.iter().enumerate() {
        let pos = Vec3::new(p.x, p.y, p.z) * MACRO_RENDER_SIZE;
        if i < entities.0.len() {
            if let Ok(mut transform) = transforms.get_mut(entities.0[i]) {
                transform.translation = pos;
            }
        } else {
            let entity = commands
                .spawn((
                    Mesh3d(assets.mesh.clone()),
                    MeshMaterial3d(assets.material.clone()),
                    Transform::from_translation(pos),
                    Visibility::default(),
                    DebrisParticleVisual,
                ))
                .id();
            entities.0.push(entity);
        }
    }
    while entities.0.len() > live.len() {
        if let Some(entity) = entities.0.pop() {
            commands.entity(entity).despawn();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::{ObjectStateDelta, VoxelServerMessage};

    #[test]
    fn debris_kind_maps_server_flag_bits() {
        // Server PartState: damaged 0x01, destroyed 0x02, part_destroyed 0x04;
        // destroy_completely sets damaged|destroyed = 0x03.
        assert_eq!(debris_kind(0x00), None);
        assert_eq!(debris_kind(FLAG_DAMAGED), Some(DebrisKind::Damaged));
        assert_eq!(
            debris_kind(FLAG_PART_DESTROYED),
            Some(DebrisKind::PartDestroyed)
        );
        assert_eq!(debris_kind(FLAG_DESTROYED), Some(DebrisKind::Destroyed));
        // damaged|destroyed (0x03) → Destroyed dominates.
        assert_eq!(
            debris_kind(FLAG_DAMAGED | FLAG_DESTROYED),
            Some(DebrisKind::Destroyed)
        );
    }

    #[test]
    fn chunk_center_is_macro_center() {
        // chunk (1,0,-1) center = (1*16+8, 0*16+8, -1*16+8) = (24, 8, -8).
        let p = chunk_center_macro([1, 0, -1]);
        assert_eq!((p.x, p.y, p.z), (24.0, 8.0, -8.0));
    }

    fn test_app() -> App {
        let mut app = App::new();
        app.insert_resource(VoxelAuthority::default())
            .init_resource::<DebrisEffect>()
            .init_resource::<DebrisEntities>()
            .init_resource::<Time>()
            .insert_resource(Assets::<Mesh>::default())
            .insert_resource(DebrisRenderAssets {
                mesh: Handle::default(),
                material: Handle::default(),
            })
            .add_systems(
                Update,
                (spawn_debris_from_object_state, advance_and_render_debris).chain(),
            );
        app
    }

    fn object_destroyed(object_id: u64, affected: Vec<[i32; 3]>) -> ObjectStateDelta {
        ObjectStateDelta {
            logical_scene_id: 1,
            object_id,
            object_version: 1,
            state_flags: FLAG_DAMAGED | FLAG_DESTROYED, // 0x03 = a destroyed object
            attribute_patch_count: 0,
            tag_patch_count: 0,
            affected_chunks: affected,
        }
    }

    #[test]
    fn object_destruction_spawns_debris_burst_and_entities() {
        let mut app = test_app();

        // Drive the authority the way the net→ingest path does, then update.
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            authority.enqueue(VoxelServerMessage::ObjectStateDelta(object_destroyed(
                7,
                vec![[0, 0, 0], [1, 0, 0]],
            )));
            authority.drain_inbox();
        }
        app.update();

        // 2 affected chunks × burst 8 = 16 particles, and a matching entity pool.
        let effect = app.world().resource::<DebrisEffect>();
        assert_eq!(effect.sim.active_count(), 16);
        let entities = app.world().resource::<DebrisEntities>();
        assert_eq!(entities.0.len(), 16);
    }

    #[test]
    fn debris_decays_and_pool_shrinks_to_zero() {
        let mut app = test_app();
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            authority.enqueue(VoxelServerMessage::ObjectStateDelta(object_destroyed(
                9,
                vec![[0, 0, 0]],
            )));
            authority.drain_inbox();
        }
        app.update();
        assert_eq!(app.world().resource::<DebrisEffect>().sim.active_count(), 8);

        // Advance past the 800ms particle lifetime → all expire, pool drains.
        app.world_mut()
            .resource_mut::<Time>()
            .advance_by(std::time::Duration::from_millis(900));
        app.update();
        assert_eq!(app.world().resource::<DebrisEffect>().sim.active_count(), 0);
        assert_eq!(app.world().resource::<DebrisEntities>().0.len(), 0);
    }

    #[test]
    fn non_destruction_event_spawns_no_debris() {
        let mut app = test_app();
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            let mut delta = object_destroyed(3, vec![[0, 0, 0]]);
            delta.state_flags = 0; // no destruction bits
            authority.enqueue(VoxelServerMessage::ObjectStateDelta(delta));
            authority.drain_inbox();
        }
        app.update();
        assert_eq!(app.world().resource::<DebrisEffect>().sim.active_count(), 0);
    }
}
