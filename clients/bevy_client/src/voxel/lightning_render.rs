//! Lightning Bevy adapter: wires the pure [`LightningSimulation`] into the app so
//! an electric DISCHARGE (the server's `ElectricDischargeKernel` — a breakdown
//! arc) draws a flickering bolt across the ionized channel.
//!
//! Flow (mirrors debris / heat_smoke — pure sim + thin ECS shell):
//!   1. The authority surfaces a `DischargeEvent` per 0x73 carrying an ionization
//!      layer (its own channel, disjoint from heat-smoke's electric drain).
//!   2. `spawn_lightning` (Logic, after ingest) calls the pure `infer_strike` to
//!      turn the channel into source→target endpoints + a stable seed, then
//!      `sim.strike`.
//!   3. `advance_and_render_lightning` (Render) ages the bolts and syncs a pooled
//!      set of thin emissive boxes to `sim.segments()` — each box stretched and
//!      oriented along one jagged segment. The shared material's opacity tracks
//!      `max_life()`, so the whole set fades as the brightest bolt decays.
//!
//! UNIT NOTE: `infer_strike` already emits WORLD-unit endpoints (it bakes in the
//! macro world size), so — like heat_smoke — the adapter does NOT scale positions.
//!
//! The geometry/decay is the assertable half (Layer-1, in `lightning.rs`); the box
//! sync + glow is the GPU half (Layer-3 pixel test).

use bevy::prelude::*;

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority_plugin::{VoxelAuthority, VoxelIngestSet};
use crate::voxel::lightning::{DischargeField, LightningSimulation, infer_strike};

/// World-unit cross-section of a bolt segment box (thin ribbon). Bolts span up to
/// ~1000 world units, so a few units reads as a sharp arc.
const BOLT_THICKNESS_WORLD: f32 = 7.0;

/// Resource: the pure lightning sim plus a monotonic salt so repeated arcs on the
/// SAME channel still draw distinct jagged bolts (folded into the strike seed).
#[derive(Resource, Default)]
pub struct LightningEffect {
    sim: LightningSimulation,
    strike_salt: i32,
}

/// Shared unit-cube mesh + emissive cyan material for every bolt segment (one draw
/// setup; the material's alpha is modulated each frame by `max_life()`).
#[derive(Resource)]
pub struct LightningRenderAssets {
    mesh: Handle<Mesh>,
    material: Handle<StandardMaterial>,
}

/// Pool of live bolt-segment box entities; index-aligned with `sim.segments()`.
#[derive(Resource, Default)]
pub struct LightningEntities(Vec<Entity>);

/// Marker for a bolt-segment entity (scopes the sync query).
#[derive(Component)]
pub struct LightningSegmentVisual;

pub struct LightningPlugin;

impl Plugin for LightningPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<LightningEffect>()
            .init_resource::<LightningEntities>()
            .add_systems(Startup, setup_lightning_assets)
            .add_systems(
                Update,
                spawn_lightning
                    .in_set(ClientSet::Logic)
                    .after(VoxelIngestSet)
                    .run_if(in_state(AppState::Game)),
            )
            .add_systems(
                Update,
                advance_and_render_lightning
                    .in_set(ClientSet::Render)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

fn setup_lightning_assets(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
) {
    // Unit cube stretched per-segment; bright cyan-white, unlit so it glows
    // regardless of scene lighting, alpha-blended so it fades with the bolt life.
    let mesh = meshes.add(Cuboid::from_length(1.0));
    let material = materials.add(StandardMaterial {
        base_color: Color::srgba(0.6, 0.9, 1.0, 1.0),
        emissive: LinearRgba::rgb(0.4, 0.8, 1.0),
        unlit: true,
        alpha_mode: AlphaMode::Blend,
        ..default()
    });
    commands.insert_resource(LightningRenderAssets { mesh, material });
}

fn spawn_lightning(mut authority: ResMut<VoxelAuthority>, mut effect: ResMut<LightningEffect>) {
    let events = authority.take_discharge_events();
    if events.is_empty() {
        return;
    }
    for event in &events {
        let field = DischargeField {
            region_id: event.region_id,
            chunk_coord: event.chunk_coord,
            macro_indices: &event.macro_indices,
            electric_potential: &event.electric_potential,
            ionization: &event.ionization,
        };
        if let Some((source, target, seed)) = infer_strike(&field, effect.strike_salt) {
            effect.sim.strike(source, target, seed);
            effect.strike_salt = effect.strike_salt.wrapping_add(1);
        }
    }
}

fn advance_and_render_lightning(
    mut commands: Commands,
    time: Res<Time>,
    mut effect: ResMut<LightningEffect>,
    mut entities: ResMut<LightningEntities>,
    assets: Option<Res<LightningRenderAssets>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    mut transforms: Query<&mut Transform, With<LightningSegmentVisual>>,
) {
    let Some(assets) = assets else {
        return; // assets not ready yet (first frame ordering)
    };

    effect.sim.update(time.delta_secs() * 1000.0);
    let segments = effect.sim.segments();

    // Whole-set opacity tracks the brightest live bolt (the sim's max_life). One
    // shared material, so all segments fade together — acceptable for sub-500ms
    // bolts (rarely more than one or two overlap).
    if let Some(material) = materials.get_mut(&assets.material) {
        material.base_color.set_alpha(effect.sim.max_life());
    }

    // Index-aligned pool sync: a thin box per segment, stretched + oriented along it.
    for (i, seg) in segments.iter().enumerate() {
        let transform = segment_transform(seg[0], seg[1]);
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
                    LightningSegmentVisual,
                ))
                .id();
            entities.0.push(entity);
        }
    }
    while entities.0.len() > segments.len() {
        if let Some(entity) = entities.0.pop() {
            commands.entity(entity).despawn();
        }
    }
}

/// Transform that maps the shared unit cube onto the segment `start→end`: centered
/// at the midpoint, cross-section `BOLT_THICKNESS_WORLD`, length along local +Z
/// rotated to the segment direction. Degenerate (zero-length) segments collapse to
/// a near-zero box (invisible) rather than producing a NaN rotation.
fn segment_transform(start: [f32; 3], end: [f32; 3]) -> Transform {
    let a = Vec3::from_array(start);
    let b = Vec3::from_array(end);
    let delta = b - a;
    let len = delta.length();
    let mid = (a + b) * 0.5;
    if len < 1e-4 {
        return Transform::from_translation(mid).with_scale(Vec3::splat(1e-4));
    }
    let rotation = Quat::from_rotation_arc(Vec3::Z, delta / len);
    Transform {
        translation: mid,
        rotation,
        scale: Vec3::new(BOLT_THICKNESS_WORLD, BOLT_THICKNESS_WORLD, len),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::{
        FIELD_MASK_ELECTRIC_POTENTIAL, FIELD_MASK_IONIZATION, FieldRegionSnapshot,
        VoxelServerMessage,
    };

    fn test_app() -> App {
        let mut app = App::new();
        app.insert_resource(VoxelAuthority::default())
            .init_resource::<LightningEffect>()
            .init_resource::<LightningEntities>()
            .init_resource::<Time>()
            .insert_resource(Assets::<Mesh>::default())
            .insert_resource(Assets::<StandardMaterial>::default());
        let material = app
            .world_mut()
            .resource_mut::<Assets<StandardMaterial>>()
            .add(StandardMaterial::default());
        app.insert_resource(LightningRenderAssets {
            mesh: Handle::default(),
            material,
        })
        .add_systems(Update, (spawn_lightning, advance_and_render_lightning).chain());
        app
    }

    fn discharge_snapshot(region_id: u64) -> FieldRegionSnapshot {
        // Three ionized cells (indices 0,1,2) with a potential gradient → a strike.
        FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [0, 0, 0],
            region_id,
            tick_count: 1,
            field_mask: FIELD_MASK_ELECTRIC_POTENTIAL | FIELD_MASK_IONIZATION,
            macro_indices: vec![0, 1, 2],
            temperature: vec![],
            electric_potential: vec![200.0, 50.0, -30.0],
            electric_current: vec![],
            ionization: vec![200, 180, 160],
            light: vec![],
        }
    }

    #[test]
    fn discharge_strikes_a_bolt_and_spawns_segment_entities() {
        let mut app = test_app();
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(discharge_snapshot(5)));
            authority.drain_inbox();
        }
        app.update();

        let effect = app.world().resource::<LightningEffect>();
        assert_eq!(effect.sim.active_count(), 1, "one bolt struck");
        let entities = app.world().resource::<LightningEntities>();
        // 18 main + 2*4 branch = 26 segment boxes.
        assert_eq!(entities.0.len(), 26);
    }

    #[test]
    fn bolt_expires_and_segment_pool_drains() {
        let mut app = test_app();
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(discharge_snapshot(5)));
            authority.drain_inbox();
        }
        app.update();
        assert!(app.world().resource::<LightningEffect>().sim.active_count() > 0);

        // Past the 480ms ttl → the bolt expires and the box pool drains.
        app.world_mut()
            .resource_mut::<Time>()
            .advance_by(std::time::Duration::from_millis(500));
        app.update();
        assert_eq!(app.world().resource::<LightningEffect>().sim.active_count(), 0);
        assert_eq!(app.world().resource::<LightningEntities>().0.len(), 0);
    }

    #[test]
    fn non_ionized_snapshot_strikes_nothing() {
        let mut app = test_app();
        {
            let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
            // Potential-only (no ionization layer) → no discharge event → no bolt.
            authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(FieldRegionSnapshot {
                logical_scene_id: 1,
                chunk_coord: [0, 0, 0],
                region_id: 9,
                tick_count: 1,
                field_mask: FIELD_MASK_ELECTRIC_POTENTIAL,
                macro_indices: vec![0, 1],
                temperature: vec![],
                electric_potential: vec![100.0, 0.0],
                electric_current: vec![],
                ionization: vec![],
                light: vec![],
            }));
            authority.drain_inbox();
        }
        app.update();
        assert_eq!(app.world().resource::<LightningEffect>().sim.active_count(), 0);
        assert_eq!(app.world().resource::<LightningEntities>().0.len(), 0);
    }

    #[test]
    fn segment_transform_centers_and_stretches_along_direction() {
        // A straight vertical segment → box centered at midpoint, z-scale = length.
        let t = segment_transform([0.0, 0.0, 0.0], [0.0, 100.0, 0.0]);
        assert!((t.translation - Vec3::new(0.0, 50.0, 0.0)).length() < 1e-3);
        assert!((t.scale.z - 100.0).abs() < 1e-3, "length along local +Z");
        assert!((t.scale.x - BOLT_THICKNESS_WORLD).abs() < 1e-3);
        // local +Z must rotate onto +Y.
        let dir = t.rotation * Vec3::Z;
        assert!((dir - Vec3::Y).length() < 1e-3);
    }

    #[test]
    fn degenerate_segment_collapses_without_nan() {
        let t = segment_transform([5.0, 5.0, 5.0], [5.0, 5.0, 5.0]);
        assert!(t.scale.x.is_finite() && t.rotation.is_finite());
        assert!(t.scale.length() < 1e-3, "zero-length segment is invisible");
    }
}
