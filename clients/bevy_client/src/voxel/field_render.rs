//! FieldView rendering (C3): turns the [`VoxelFieldStore`]'s dirty field regions
//! into Bevy temperature-overlay entities — the FieldView render sub-layer,
//! parallel to ChunkMesh / SurfaceDecal.
//!
//! Each field region (keyed by `region_id`) becomes ONE overlay `Mesh3d` entity:
//! marker cubes at macro cells hotter than [`DEFAULT_HEAT_THRESHOLD_C`], colored
//! by heat bucket (the [`heat_color`] ramp baked per-vertex), placed at the
//! region's chunk origin via the SAME [`chunk_translation`] the chunk mesh uses
//! (so the overlay registers exactly over its cells). The overlay material is
//! **unlit** so the markers read as glowing heat regardless of scene lighting.
//!
//! Rebuilt only when the field store marks the region dirty; despawned when the
//! region cools below threshold (overlay meshes to nothing) or is destroyed
//! (0x74). The render adapter reads committed field truth only — no fabrication,
//! same authority discipline as the chunk renderer.

use bevy::prelude::*;
use std::collections::HashMap;

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority_plugin::VoxelAuthority;
use crate::voxel::chunk_render::{MACRO_RENDER_SIZE, build_mesh_with_colors, chunk_translation};
use crate::voxel::field_view::{DEFAULT_HEAT_THRESHOLD_C, heat_color, temperature_overlay_mesh};

/// Maps each rendered field region (`region_id`) to its Bevy overlay entity, so
/// a newer snapshot updates in place and a destroyed/cooled region despawns.
#[derive(Resource, Default)]
pub struct VoxelFieldEntities(HashMap<u64, Entity>);

/// Shared unlit material for all field overlay meshes — vertex heat colors come
/// through at full intensity (markers read as glowing hot), independent of scene
/// lighting. Like the chunk material, one shared handle keeps overlays batchable.
#[derive(Resource)]
pub struct VoxelFieldMaterial(Handle<StandardMaterial>);

pub struct VoxelFieldRenderPlugin;

impl Plugin for VoxelFieldRenderPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<VoxelFieldEntities>()
            .add_systems(Startup, setup_field_material)
            .add_systems(
                Update,
                render_dirty_field_regions
                    .in_set(ClientSet::Render)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

fn setup_field_material(mut commands: Commands, mut materials: ResMut<Assets<StandardMaterial>>) {
    // Unlit white base: the baked per-vertex heat colors render unattenuated, so
    // a hot marker glows the same whether the chunk around it is lit or shadowed.
    let handle = materials.add(StandardMaterial {
        base_color: Color::WHITE,
        unlit: true,
        ..default()
    });
    commands.insert_resource(VoxelFieldMaterial(handle));
}

fn render_dirty_field_regions(
    mut commands: Commands,
    mut authority: ResMut<VoxelAuthority>,
    mut entities: ResMut<VoxelFieldEntities>,
    mut meshes: ResMut<Assets<Mesh>>,
    material: Option<Res<VoxelFieldMaterial>>,
) {
    let Some(material) = material else {
        return; // material not ready yet (first frame ordering)
    };

    for region_id in authority.field_store.take_dirty() {
        match authority.field_store.region(region_id) {
            Some(region) => {
                let data =
                    temperature_overlay_mesh(region, MACRO_RENDER_SIZE, DEFAULT_HEAT_THRESHOLD_C);
                if data.is_empty() {
                    // Region present but no cell over threshold (cooled) → no overlay.
                    despawn_field(&mut commands, &mut entities, region_id);
                } else {
                    let mesh_handle = meshes.add(build_mesh_with_colors(&data, heat_color));
                    let translation = chunk_translation(region.chunk_coord);
                    upsert_field(
                        &mut commands,
                        &mut entities,
                        &material,
                        region_id,
                        mesh_handle,
                        translation,
                    );
                }
            }
            // Region gone (destroyed/0x74) → remove its overlay entity.
            None => despawn_field(&mut commands, &mut entities, region_id),
        }
    }
}

/// Spawns or updates the region's overlay mesh entity in place at its chunk
/// origin (the marker cubes carry chunk-local coords, like the chunk mesh).
fn upsert_field(
    commands: &mut Commands,
    entities: &mut VoxelFieldEntities,
    material: &VoxelFieldMaterial,
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

fn despawn_field(commands: &mut Commands, entities: &mut VoxelFieldEntities, region_id: u64) {
    if let Some(entity) = entities.0.remove(&region_id) {
        commands.entity(entity).despawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::{
        FIELD_MASK_TEMPERATURE, FieldRegionDestroyed, FieldRegionSnapshot, VoxelServerMessage,
    };

    /// Builds a headless App with just the field render system + the resources it
    /// reads. `Assets::<Mesh>::default()` allocates handles via its own internal
    /// allocator, so no AssetServer / GPU is needed; the material handle is never
    /// dereferenced (only cloned onto entities), so a default handle suffices.
    fn test_app() -> App {
        let mut app = App::new();
        app.insert_resource(VoxelAuthority::default())
            .init_resource::<VoxelFieldEntities>()
            .insert_resource(Assets::<Mesh>::default())
            .insert_resource(VoxelFieldMaterial(Handle::default()))
            .add_systems(Update, render_dirty_field_regions);
        app
    }

    fn hot_region(
        region_id: u64,
        chunk_coord: [i32; 3],
        cells: &[(u16, f32)],
    ) -> FieldRegionSnapshot {
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

    fn field_entity_count(app: &App) -> usize {
        app.world().resource::<VoxelFieldEntities>().0.len()
    }

    #[test]
    fn hot_region_spawns_overlay_then_destroy_despawns_it() {
        let mut app = test_app();

        // A region with a hot cell (300 over threshold) → overlay spawns at the
        // region's chunk origin.
        let chunk_coord = [1, 0, -2];
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(hot_region(7, chunk_coord, &[(0, 300.0)])),
        );
        app.update();
        assert_eq!(field_entity_count(&app), 1, "hot region must spawn overlay");

        // The overlay carries a Mesh3d and sits at chunk_translation(chunk_coord)
        // — i.e. registered exactly over the chunk the field belongs to.
        let entity = *app
            .world()
            .resource::<VoxelFieldEntities>()
            .0
            .get(&7)
            .unwrap();
        assert!(
            app.world().get::<Mesh3d>(entity).is_some(),
            "overlay entity must have a mesh"
        );
        let transform = app.world().get::<Transform>(entity).expect("has transform");
        assert_eq!(transform.translation, chunk_translation(chunk_coord));

        // Destroy (0x74) → overlay despawns, entity removed from the registry.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionDestroyed(FieldRegionDestroyed {
                logical_scene_id: 1,
                chunk_coord,
                region_id: 7,
                destroy_reason: 0,
            }),
        );
        app.update();
        assert_eq!(field_entity_count(&app), 0, "destroy must despawn overlay");
        assert!(app.world().get_entity(entity).is_err());
    }

    #[test]
    fn region_with_no_cell_over_threshold_spawns_nothing() {
        let mut app = test_app();
        // All cells below DEFAULT_HEAT_THRESHOLD_C → empty overlay → no entity.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(hot_region(
                3,
                [0, 0, 0],
                &[(0, 10.0), (5, 20.0)],
            )),
        );
        app.update();
        assert_eq!(field_entity_count(&app), 0);
    }

    #[test]
    fn cooled_region_despawns_previously_spawned_overlay() {
        let mut app = test_app();
        // First: hot → spawns.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(hot_region(9, [0, 0, 0], &[(0, 500.0)])),
        );
        app.update();
        assert_eq!(field_entity_count(&app), 1);

        // Newer snapshot for the same region, now cooled below threshold → the
        // overlay despawns (no fabricated geometry left behind).
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(hot_region(9, [0, 0, 0], &[(0, 10.0)])),
        );
        app.update();
        assert_eq!(field_entity_count(&app), 0);
    }
}
