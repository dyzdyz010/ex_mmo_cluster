//! Heat-smoke Bevy adapter: wires the pure [`HeatSmokeSimulation`] into the app
//! so Joule heating along powered circuits produces rising smoke — the
//! reference's PRIMARY heat visual.
//!
//! Flow (mirrors the debris adapter): the authority surfaces an
//! `ElectricSnapshotEvent` per electric 0x73 (edge-triggered, disjoint from the
//! overlay's `take_dirty`); `spawn_heat_smoke` (Logic) emits a burst per event;
//! `advance_and_render_heat_smoke` (Render) integrates + syncs a pooled set of
//! gray translucent cubes to `live_particles()`.
//!
//! UNIT NOTE: heat-smoke positions are ALREADY in world units (the sim
//! pre-multiplies by the macro world size), so — unlike debris — the adapter
//! does NOT scale translations. Per-particle `size_world` drives the cube scale.

use bevy::prelude::*;

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority_plugin::{VoxelAuthority, VoxelIngestSet};
use crate::voxel::heat_smoke::{ElectricField, HeatSmokeSimulation};

/// Resource: the pure heat-smoke sim plus the PRNG state feeding its injected
/// random (a small xorshift, like the debris adapter).
#[derive(Resource)]
pub struct HeatSmokeEffect {
    sim: HeatSmokeSimulation,
    rng_state: u64,
}

impl Default for HeatSmokeEffect {
    fn default() -> Self {
        Self {
            sim: HeatSmokeSimulation::new(),
            rng_state: 0x9E37_79B9_7F4A_7C15,
        }
    }
}

/// Shared unit-cube mesh + gray translucent material for all smoke particles.
#[derive(Resource)]
pub struct HeatSmokeRenderAssets {
    mesh: Handle<Mesh>,
    material: Handle<StandardMaterial>,
}

/// Pool of live smoke cube entities; index-aligned with `live_particles()`.
#[derive(Resource, Default)]
pub struct HeatSmokeEntities(Vec<Entity>);

/// Marker for a smoke cube entity (scopes the sync query).
#[derive(Component)]
pub struct HeatSmokeVisual;

pub struct HeatSmokePlugin;

impl Plugin for HeatSmokePlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<HeatSmokeEffect>()
            .init_resource::<HeatSmokeEntities>()
            .add_systems(Startup, setup_heat_smoke_assets)
            .add_systems(
                Update,
                spawn_heat_smoke
                    .in_set(ClientSet::Logic)
                    .after(VoxelIngestSet)
                    .run_if(in_state(AppState::Game)),
            )
            .add_systems(
                Update,
                advance_and_render_heat_smoke
                    .in_set(ClientSet::Render)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

fn setup_heat_smoke_assets(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
) {
    // Unit cube scaled per-particle by `size_world`; gray + translucent so smoke
    // reads as a soft volume (alpha-blended, unlit so it doesn't pick up scene
    // shading oddly).
    let mesh = meshes.add(Cuboid::from_length(1.0));
    let material = materials.add(StandardMaterial {
        base_color: Color::srgba(0.55, 0.55, 0.58, 0.5),
        unlit: true,
        alpha_mode: AlphaMode::Blend,
        ..default()
    });
    commands.insert_resource(HeatSmokeRenderAssets { mesh, material });
}

/// Advances the PRNG (xorshift64) and returns a value in `[0, 1)`.
fn next_unit(state: &mut u64) -> f32 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    ((x >> 40) as f32) / ((1u64 << 24) as f32)
}

fn spawn_heat_smoke(mut authority: ResMut<VoxelAuthority>, mut effect: ResMut<HeatSmokeEffect>) {
    // A destroyed field region clears its smoke + heat-source override at once
    // (mirrors web onRegionDestroyed → clearRegion), so no plume lingers over a
    // region that no longer exists.
    for region_id in authority.take_destroyed_field_regions() {
        effect.sim.clear_region(region_id);
    }

    let events = authority.take_electric_snapshot_events();
    if events.is_empty() {
        return;
    }
    // Split-borrow so the rng closure (borrows rng_state) and sim coexist.
    let HeatSmokeEffect { sim, rng_state } = &mut *effect;
    for event in &events {
        let field = ElectricField {
            region_id: event.region_id,
            chunk_coord: event.chunk_coord,
            field_mask: event.field_mask,
            macro_indices: &event.macro_indices,
            electric_potential: &event.electric_potential,
            electric_current: &event.electric_current,
        };
        let mut rng = || next_unit(rng_state);
        sim.spawn_from_electric(&field, &mut rng);
    }
}

fn advance_and_render_heat_smoke(
    mut commands: Commands,
    time: Res<Time>,
    mut effect: ResMut<HeatSmokeEffect>,
    mut entities: ResMut<HeatSmokeEntities>,
    assets: Option<Res<HeatSmokeRenderAssets>>,
    mut transforms: Query<&mut Transform, With<HeatSmokeVisual>>,
) {
    let Some(assets) = assets else {
        return; // assets not ready yet (first frame ordering)
    };

    effect.sim.update(time.delta_secs() * 1000.0);
    let live = effect.sim.live_particles();

    // Index-aligned pool sync. Positions are WORLD units (no macro scaling);
    // per-particle size drives the cube scale.
    for (i, p) in live.iter().enumerate() {
        let transform = Transform::from_translation(Vec3::new(p.x, p.y, p.z))
            .with_scale(Vec3::splat(p.size_world));
        if i < entities.0.len() {
            if let Ok(mut existing) = transforms.get_mut(entities.0[i]) {
                *existing = transform;
            }
        } else {
            let entity = commands
                .spawn((
                    Mesh3d(assets.mesh.clone()),
                    MeshMaterial3d(assets.material.clone()),
                    transform,
                    Visibility::default(),
                    HeatSmokeVisual,
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
    use crate::voxel::wire::{
        FIELD_MASK_ELECTRIC_CURRENT, FieldRegionDestroyed, FieldRegionSnapshot, VoxelServerMessage,
    };

    fn test_app() -> App {
        let mut app = App::new();
        app.insert_resource(VoxelAuthority::default())
            .init_resource::<HeatSmokeEffect>()
            .init_resource::<HeatSmokeEntities>()
            .init_resource::<Time>()
            .insert_resource(Assets::<Mesh>::default())
            .insert_resource(HeatSmokeRenderAssets {
                mesh: Handle::default(),
                material: Handle::default(),
            })
            .add_systems(
                Update,
                (spawn_heat_smoke, advance_and_render_heat_smoke).chain(),
            );
        app
    }

    fn electric_snapshot(region_id: u64, current: Vec<f32>) -> FieldRegionSnapshot {
        let macro_indices: Vec<u16> = (0..current.len() as u16).collect();
        FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id,
            tick_count: 1,
            field_mask: FIELD_MASK_ELECTRIC_CURRENT,
            macro_indices,
            temperature: vec![],
            electric_potential: vec![],
            electric_current: current,
            ionization: vec![],
        }
    }

    #[test]
    fn electric_snapshot_spawns_smoke_and_entities() {
        let mut app = test_app();
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            // max|I| = 5000 → heat 5000*120*0.1 = 60000; heatScale 250;
            // ceil(2*250)=500 → clamped to maxSpawnPerSnapshot 96.
            authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(electric_snapshot(
                7,
                vec![5000.0, 4000.0],
            )));
            authority.drain_inbox();
        }
        app.update();

        let effect = app.world().resource::<HeatSmokeEffect>();
        assert_eq!(effect.sim.active_count(None), 96);
        let entities = app.world().resource::<HeatSmokeEntities>();
        assert_eq!(entities.0.len(), 96);
    }

    #[test]
    fn region_destroy_clears_its_smoke_immediately() {
        let mut app = test_app();
        // Spawn smoke for region 7.
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(electric_snapshot(
                7,
                vec![10.0],
            )));
            authority.drain_inbox();
        }
        app.update();
        assert!(
            app.world()
                .resource::<HeatSmokeEffect>()
                .sim
                .active_count(Some(7))
                > 0
        );

        // Destroying region 7 must clear its plume the same pass (not let it age).
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            authority.enqueue(VoxelServerMessage::FieldRegionDestroyed(
                FieldRegionDestroyed {
                    logical_scene_id: 1,
                    chunk_coord: [0, 0, 0],
                    region_id: 7,
                    destroy_reason: 0,
                },
            ));
            authority.drain_inbox();
        }
        app.update();
        assert_eq!(
            app.world()
                .resource::<HeatSmokeEffect>()
                .sim
                .active_count(Some(7)),
            0,
            "destroy clears the region's smoke"
        );
    }

    #[test]
    fn smoke_decays_and_pool_shrinks() {
        let mut app = test_app();
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(electric_snapshot(
                9,
                vec![1.0],
            )));
            authority.drain_inbox();
        }
        app.update();
        assert!(
            app.world()
                .resource::<HeatSmokeEffect>()
                .sim
                .active_count(None)
                > 0
        );

        // Past the 2200ms lifetime → all expire, pool drains.
        app.world_mut()
            .resource_mut::<Time>()
            .advance_by(std::time::Duration::from_millis(2300));
        app.update();
        assert_eq!(
            app.world()
                .resource::<HeatSmokeEffect>()
                .sim
                .active_count(None),
            0
        );
        assert_eq!(app.world().resource::<HeatSmokeEntities>().0.len(), 0);
    }
}
