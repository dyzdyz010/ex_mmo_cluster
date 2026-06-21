//! Thermal-incandescence Bevy adapter (emergent optics, increment 1): turns the
//! temperature field into an ADDITIVE blackbody glow per region — the visual
//! payoff of "hot things glow" derived purely from streamed temperature truth.
//!
//! Mirrors [`crate::voxel::field_render`] (one entity per region, rebuilt on
//! dirty, despawned when it cools below the Draper point or the region is
//! destroyed), but with two deliberate differences:
//!   * It drains the field store's INCANDESCENCE dirty channel
//!     (`take_incandescence_dirty`), disjoint from the overlay's `take_dirty`, so
//!     the two render layers never contend.
//!   * Its material is ADDITIVE (`AlphaMode::Add`) + unlit + depth-disabled — so
//!     the glow brightens whatever's behind it (a real emissive halo, not a
//!     translucent debug tint) and isn't occluded by the hot cell's own face.
//!
//! Reuses the registered `FieldOverlayMaterial` type (no second MaterialPlugin)
//! and the `incandescence_color` ramp baked per-vertex.

use bevy::prelude::*;
use std::collections::HashMap;

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority_plugin::VoxelAuthority;
use crate::voxel::chunk_render::{MACRO_RENDER_SIZE, build_mesh_with_colors, chunk_translation};
use crate::voxel::field_render::{FieldDepthDisable, FieldOverlayMaterial};
use crate::voxel::incandescence::{incandescence_color, incandescence_mesh};

/// Shared additive-emissive glow material (unlit + `AlphaMode::Add` + depth
/// disable). Same `FieldOverlayMaterial` type as the overlay (its MaterialPlugin
/// is already registered), just an additive instance.
pub(crate) fn incandescence_glow_material() -> FieldOverlayMaterial {
    FieldOverlayMaterial {
        base: StandardMaterial {
            base_color: Color::WHITE,
            unlit: true,
            alpha_mode: AlphaMode::Add,
            ..default()
        },
        extension: FieldDepthDisable::default(),
    }
}

/// Maps each region to its glow entity (one per region: a single temperature-driven
/// glow mesh), so a newer snapshot updates it in place and a cooled/destroyed
/// region despawns it.
#[derive(Resource, Default)]
pub struct IncandescenceEntities(HashMap<u64, Entity>);

/// The shared additive glow material handle.
#[derive(Resource)]
pub struct IncandescenceMaterial(Handle<FieldOverlayMaterial>);

pub struct IncandescencePlugin;

impl Plugin for IncandescencePlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<IncandescenceEntities>()
            .add_systems(Startup, setup_incandescence_material)
            .add_systems(
                Update,
                render_dirty_incandescence
                    .in_set(ClientSet::Render)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

fn setup_incandescence_material(
    mut commands: Commands,
    mut materials: ResMut<Assets<FieldOverlayMaterial>>,
) {
    let handle = materials.add(incandescence_glow_material());
    commands.insert_resource(IncandescenceMaterial(handle));
}

fn render_dirty_incandescence(
    mut commands: Commands,
    mut authority: ResMut<VoxelAuthority>,
    mut entities: ResMut<IncandescenceEntities>,
    mut meshes: ResMut<Assets<Mesh>>,
    material: Option<Res<IncandescenceMaterial>>,
) {
    let Some(material) = material else {
        return; // material not ready yet (first frame ordering)
    };

    for region_id in authority.field_store.take_incandescence_dirty() {
        let region = authority.field_store.region(region_id);
        let data = region.map(|r| incandescence_mesh(r, MACRO_RENDER_SIZE));
        match data {
            // The region still has glowing (above-Draper) cells → upsert its glow.
            Some(data) if !data.positions.is_empty() => {
                let mesh_handle = meshes.add(build_mesh_with_colors(&data, incandescence_color));
                let translation = chunk_translation(region.unwrap().chunk_coord);
                upsert_glow(
                    &mut commands,
                    &mut entities,
                    &material,
                    region_id,
                    mesh_handle,
                    translation,
                );
            }
            // Region cooled below the Draper point (no glowing cells) or destroyed
            // → despawn its glow (no fabricated light left behind).
            _ => despawn_glow(&mut commands, &mut entities, region_id),
        }
    }
}

fn upsert_glow(
    commands: &mut Commands,
    entities: &mut IncandescenceEntities,
    material: &IncandescenceMaterial,
    region_id: u64,
    mesh_handle: Handle<Mesh>,
    translation: Vec3,
) {
    match entities.0.get(&region_id).copied() {
        Some(entity) => {
            commands.entity(entity).insert((
                Mesh3d(mesh_handle),
                Transform::from_translation(translation),
            ));
        }
        None => {
            let entity = commands
                .spawn((
                    Mesh3d(mesh_handle),
                    MeshMaterial3d(material.0.clone()),
                    Transform::from_translation(translation),
                    Visibility::default(),
                ))
                .id();
            entities.0.insert(region_id, entity);
        }
    }
}

fn despawn_glow(commands: &mut Commands, entities: &mut IncandescenceEntities, region_id: u64) {
    if let Some(entity) = entities.0.remove(&region_id) {
        commands.entity(entity).despawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::{
        FIELD_MASK_ELECTRIC_CURRENT, FIELD_MASK_TEMPERATURE, FieldRegionDestroyed,
        FieldRegionSnapshot, VoxelServerMessage,
    };

    fn test_app() -> App {
        let mut app = App::new();
        app.insert_resource(VoxelAuthority::default())
            .init_resource::<IncandescenceEntities>()
            .insert_resource(Assets::<Mesh>::default())
            .insert_resource(IncandescenceMaterial(Handle::default()))
            .add_systems(Update, render_dirty_incandescence);
        app
    }

    fn temp_region(region_id: u64, chunk_coord: [i32; 3], cells: &[(u16, f32)]) -> FieldRegionSnapshot {
        FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord,
            region_id,
            tick_count: 1,
            field_mask: FIELD_MASK_TEMPERATURE,
            macro_indices: cells.iter().map(|(i, _)| *i).collect(),
            temperature: cells.iter().map(|(_, t)| *t).collect(),
            electric_potential: vec![],
            electric_current: vec![],
            ionization: vec![],
        }
    }

    fn ingest(app: &mut App, message: VoxelServerMessage) {
        let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
        authority.enqueue(message);
        authority.drain_inbox();
    }

    fn glow_count(app: &App) -> usize {
        app.world().resource::<IncandescenceEntities>().0.len()
    }

    #[test]
    fn hot_region_spawns_glow_then_cooling_despawns_it() {
        let mut app = test_app();
        let chunk_coord = [1, 0, -2];

        // 1200°C cell (well above Draper) → glow spawns at the region's chunk origin.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(temp_region(7, chunk_coord, &[(0, 1200.0)])),
        );
        app.update();
        assert_eq!(glow_count(&app), 1, "hot region must glow");
        let entity = *app
            .world()
            .resource::<IncandescenceEntities>()
            .0
            .get(&7)
            .unwrap();
        let transform = app.world().get::<Transform>(entity).expect("has transform");
        assert_eq!(transform.translation, chunk_translation(chunk_coord));

        // A newer snapshot below the Draper point (cooled) → glow despawns.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(temp_region(7, chunk_coord, &[(0, 100.0)])),
        );
        app.update();
        assert_eq!(glow_count(&app), 0, "cooled region stops glowing");
    }

    #[test]
    fn below_draper_region_never_glows() {
        let mut app = test_app();
        // 300°C is hot but below the Draper point (525°C) → no visible glow.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(temp_region(3, [0, 0, 0], &[(0, 300.0)])),
        );
        app.update();
        assert_eq!(glow_count(&app), 0);
    }

    #[test]
    fn destroy_despawns_glow() {
        let mut app = test_app();
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(temp_region(9, [0, 0, 0], &[(0, 1500.0)])),
        );
        app.update();
        assert_eq!(glow_count(&app), 1);

        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionDestroyed(FieldRegionDestroyed {
                logical_scene_id: 1,
                chunk_coord: [0, 0, 0],
                region_id: 9,
                destroy_reason: 0,
            }),
        );
        app.update();
        assert_eq!(glow_count(&app), 0);
    }

    #[test]
    fn electric_only_region_does_not_glow() {
        let mut app = test_app();
        // A non-temperature (electric) snapshot still marks dirty, but incandescence
        // meshes nothing for it → no glow entity.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(FieldRegionSnapshot {
                logical_scene_id: 1,
                chunk_coord: [0, 0, 0],
                region_id: 4,
                tick_count: 1,
                field_mask: FIELD_MASK_ELECTRIC_CURRENT,
                macro_indices: vec![0],
                temperature: vec![],
                electric_potential: vec![],
                electric_current: vec![5.0],
                ionization: vec![],
            }),
        );
        app.update();
        assert_eq!(glow_count(&app), 0);
    }
}
