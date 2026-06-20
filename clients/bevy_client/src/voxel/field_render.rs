//! FieldView rendering (C3): turns the [`VoxelFieldStore`]'s dirty field regions
//! into Bevy field-overlay entities — the FieldView render sub-layer, parallel
//! to ChunkMesh / SurfaceDecal.
//!
//! Each field region carries up to three field types (temperature / electric
//! potential / electric current); each becomes its OWN overlay `Mesh3d` entity,
//! keyed by `(region_id, FieldOverlayKind)` — mirroring the web reference's
//! separate per-field meshes. An overlay is marker cubes at the macro cells that
//! clear that field's threshold, colored by its reference ramp ([`field_color`]
//! baked per-vertex), placed at the region's chunk origin via the SAME
//! [`chunk_translation`] the chunk mesh uses (so the overlay registers exactly
//! over its cells). The overlay material is **unlit** so the markers read at full
//! intensity regardless of scene lighting.
//!
//! Rebuilt only when the field store marks the region dirty; an overlay despawns
//! when its field meshes to nothing (cooled / below threshold) or the region is
//! destroyed (0x74). The render adapter reads committed field truth only — no
//! fabrication, same authority discipline as the chunk renderer.

use bevy::mesh::MeshVertexBufferLayoutRef;
use bevy::pbr::{
    ExtendedMaterial, MaterialExtension, MaterialExtensionKey, MaterialExtensionPipeline,
    MaterialPlugin,
};
use bevy::prelude::*;
use bevy::render::render_resource::{
    AsBindGroup, CompareFunction, RenderPipelineDescriptor, SpecializedMeshPipelineError,
};
use std::collections::HashMap;

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority_plugin::VoxelAuthority;
use crate::voxel::chunk_render::{MACRO_RENDER_SIZE, build_mesh_with_colors, chunk_translation};
use crate::voxel::field_view::{FieldOverlayKind, field_color, overlay_mesh};

/// The field overlay material: an unlit, alpha-blended, vertex-colored
/// `StandardMaterial` PLUS a depth-disable extension so markers render THROUGH
/// solid terrain.
///
/// Why the extension: emergence overwhelmingly happens on solid voxels (heated
/// iron, powered conductors, embers), and a marker cube is inset inside the macro
/// cell — i.e. geometrically *behind* the opaque chunk face. An alpha-blended
/// material is still depth-tested against the opaque pass, so without disabling
/// the depth test the overlay is rejected exactly where it matters. The web
/// reference (`fieldDebugOverlay.ts`) sets `depthTest:false` + `depthWrite:false`
/// on every overlay material for this reason ("visible through terrain"); this is
/// the 1:1 Bevy port. (The pixel result is Layer-3-verifiable; the code intent —
/// `depth_compare = Always` — is explicit and matches the reference.)
pub(crate) type FieldOverlayMaterial = ExtendedMaterial<StandardMaterial, FieldDepthDisable>;

/// Zero-binding material extension that disables depth test/write in the overlay
/// pipeline (the rest of the shading is the base `StandardMaterial`).
#[derive(Asset, TypePath, AsBindGroup, Clone, Default)]
pub(crate) struct FieldDepthDisable {}

/// Builds the canonical field overlay material (unlit + alpha-blend + depth
/// disable). Shared by `setup_field_material` and the Layer-3 pixel test so both
/// exercise the exact same depth-disable pipeline.
pub(crate) fn field_overlay_material() -> FieldOverlayMaterial {
    FieldOverlayMaterial {
        base: StandardMaterial {
            base_color: Color::WHITE,
            unlit: true,
            alpha_mode: AlphaMode::Blend,
            ..default()
        },
        extension: FieldDepthDisable::default(),
    }
}

impl MaterialExtension for FieldDepthDisable {
    fn specialize(
        _pipeline: &MaterialExtensionPipeline,
        descriptor: &mut RenderPipelineDescriptor,
        _layout: &MeshVertexBufferLayoutRef,
        _key: MaterialExtensionKey<Self>,
    ) -> Result<(), SpecializedMeshPipelineError> {
        if let Some(depth_stencil) = descriptor.depth_stencil.as_mut() {
            // Render through opaque geometry (web depthTest:false / depthWrite:false).
            depth_stencil.depth_compare = CompareFunction::Always;
            depth_stencil.depth_write_enabled = false;
        }
        Ok(())
    }
}

/// Maps each rendered field overlay `(region_id, kind ordinal)` to its Bevy
/// entity, so a newer snapshot updates it in place and a destroyed/cooled region
/// despawns it. Separate keys per field type keep the three overlays independent.
#[derive(Resource, Default)]
pub struct VoxelFieldEntities(HashMap<(u64, u8), Entity>);

/// Shared overlay material handle (unlit + alpha-blend + depth-disable). Vertex
/// field colors come through at full intensity; one shared handle keeps overlays
/// batchable.
#[derive(Resource)]
pub struct VoxelFieldMaterial(Handle<FieldOverlayMaterial>);

pub struct VoxelFieldRenderPlugin;

impl Plugin for VoxelFieldRenderPlugin {
    fn build(&self, app: &mut App) {
        app.add_plugins(MaterialPlugin::<FieldOverlayMaterial>::default())
            .init_resource::<VoxelFieldEntities>()
            .add_systems(Startup, setup_field_material)
            .add_systems(
                Update,
                render_dirty_field_regions
                    .in_set(ClientSet::Render)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

fn setup_field_material(
    mut commands: Commands,
    mut materials: ResMut<Assets<FieldOverlayMaterial>>,
) {
    // Unlit white base so the baked per-vertex field colors render unattenuated,
    // and alpha-blended so the per-vertex alpha (temperature opacity buckets /
    // electric layer opacity) reads as a translucent overlay — mirroring the web
    // overlay's see-through debug cells. The depth-disable extension makes it
    // render through solid terrain.
    let handle = materials.add(field_overlay_material());
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
        let region = authority.field_store.region(region_id);
        // Rebuild every field type's overlay for this region. A missing region
        // (destroyed) or a field that meshes to nothing (cooled / below
        // threshold) despawns that (region, kind) overlay.
        for kind in FieldOverlayKind::ALL {
            let key = (region_id, kind.ordinal());
            let data = region.map(|r| overlay_mesh(r, kind, MACRO_RENDER_SIZE));
            match data {
                Some(data) if !data.is_empty() => {
                    let mesh_handle = meshes.add(build_mesh_with_colors(&data, field_color));
                    // region is Some here (the mesh came from it).
                    let translation = chunk_translation(region.unwrap().chunk_coord);
                    upsert_field(
                        &mut commands,
                        &mut entities,
                        &material,
                        key,
                        mesh_handle,
                        translation,
                    );
                }
                _ => despawn_field(&mut commands, &mut entities, key),
            }
        }
    }
}

/// Spawns or updates one `(region, kind)` overlay entity in place at its chunk
/// origin (the marker cubes carry chunk-local coords, like the chunk mesh).
fn upsert_field(
    commands: &mut Commands,
    entities: &mut VoxelFieldEntities,
    material: &VoxelFieldMaterial,
    key: (u64, u8),
    mesh_handle: Handle<Mesh>,
    translation: Vec3,
) {
    match entities.0.get(&key).copied() {
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
            entities.0.insert(key, entity);
        }
    }
}

fn despawn_field(commands: &mut Commands, entities: &mut VoxelFieldEntities, key: (u64, u8)) {
    if let Some(entity) = entities.0.remove(&key) {
        commands.entity(entity).despawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::{
        FIELD_MASK_ELECTRIC_CURRENT, FIELD_MASK_ELECTRIC_POTENTIAL, FIELD_MASK_TEMPERATURE,
        FieldRegionDestroyed, FieldRegionSnapshot, VoxelServerMessage,
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
        // — i.e. registered exactly over the chunk the field belongs to. Keyed by
        // (region_id, Temperature ordinal=0).
        let entity = *app
            .world()
            .resource::<VoxelFieldEntities>()
            .0
            .get(&(7, FieldOverlayKind::Temperature.ordinal()))
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
    fn region_with_only_baseline_cells_spawns_nothing() {
        let mut app = test_app();
        // All cells at the ambient baseline (20°C) → no anomaly → no overlay.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(hot_region(
                3,
                [0, 0, 0],
                &[(0, 20.0), (5, 20.0)],
            )),
        );
        app.update();
        assert_eq!(field_entity_count(&app), 0);
    }

    #[test]
    fn region_returning_to_baseline_despawns_previously_spawned_overlay() {
        let mut app = test_app();
        // First: hot anomaly → spawns.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(hot_region(9, [0, 0, 0], &[(0, 500.0)])),
        );
        app.update();
        assert_eq!(field_entity_count(&app), 1);

        // Newer snapshot for the same region, now back at baseline (no anomaly) →
        // the overlay despawns (no fabricated geometry left behind).
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(hot_region(9, [0, 0, 0], &[(0, 20.0)])),
        );
        app.update();
        assert_eq!(field_entity_count(&app), 0);
    }

    #[test]
    fn electric_region_spawns_potential_and_current_overlays_independently() {
        let mut app = test_app();
        let chunk_coord = [0, 1, 0];

        // A region carrying BOTH potential and current (active values) → two
        // independent overlays, keyed by their distinct field-kind ordinals.
        let region = FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord,
            region_id: 11,
            tick_count: 1,
            field_mask: FIELD_MASK_ELECTRIC_POTENTIAL | FIELD_MASK_ELECTRIC_CURRENT,
            macro_indices: vec![0, 5],
            temperature: vec![],
            electric_potential: vec![80.0, 12.0],
            electric_current: vec![5.0, 1.0],
            ionization: vec![],
        };
        ingest(&mut app, VoxelServerMessage::FieldRegionSnapshot(region));
        app.update();

        // No temperature layer → no temperature overlay; potential + current each
        // spawn one (region has no temperature, so exactly 2 entities total).
        assert_eq!(field_entity_count(&app), 2);
        let entities = app.world().resource::<VoxelFieldEntities>();
        assert!(
            entities
                .0
                .contains_key(&(11, FieldOverlayKind::ElectricPotential.ordinal()))
        );
        assert!(
            entities
                .0
                .contains_key(&(11, FieldOverlayKind::ElectricCurrent.ordinal()))
        );
        assert!(
            !entities
                .0
                .contains_key(&(11, FieldOverlayKind::Temperature.ordinal()))
        );

        // Destroy removes both overlays for the region.
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionDestroyed(FieldRegionDestroyed {
                logical_scene_id: 1,
                chunk_coord,
                region_id: 11,
                destroy_reason: 0,
            }),
        );
        app.update();
        assert_eq!(field_entity_count(&app), 0);
    }
}
