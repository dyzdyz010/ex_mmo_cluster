use bevy::prelude::Vec2;
use bevy_client::{
    input::commands::{MOVEMENT_FLAG_JUMP, MoveInputFrame},
    voxel::{
        BoundarySnapRequest, HotbarEntryKind, LocalPrefabRegistry, MICRO_GRID_SLOT_COUNT,
        MICRO_PER_MACRO, MacroCoord, MicroCoord, NormalBlockData, Rotation, VoxelMaterialId,
        VoxelWorld,
    },
};

fn block(material: VoxelMaterialId) -> NormalBlockData {
    NormalBlockData::new(material)
}

#[test]
fn jump_flag_is_public_and_detectable_on_input_frames() {
    let frame = MoveInputFrame {
        seq: 1,
        client_tick: 10,
        dt_ms: 100,
        input_dir: Vec2::ZERO,
        speed_scale: 1.0,
        movement_flags: MOVEMENT_FLAG_JUMP,
    };

    assert!(frame.is_jump_requested());
}

#[test]
fn microgrid_matches_web_resolution_and_bounds() {
    let mut world = VoxelWorld::new();
    let macro_coord = MacroCoord::new(4, 5, 6);
    let center = MicroCoord::new(4, 4, 4);

    assert_eq!(MICRO_PER_MACRO, 8);
    assert_eq!(MICRO_GRID_SLOT_COUNT, 512);
    assert!(world.set_micro_block(macro_coord, center, block(VoxelMaterialId::Wood)));
    assert_eq!(
        world
            .micro_block(macro_coord, center)
            .map(|block| block.material_id),
        Some(VoxelMaterialId::Wood)
    );
    assert!(!world.set_micro_block(
        macro_coord,
        MicroCoord::new(8, 0, 0),
        block(VoxelMaterialId::Stone)
    ));

    let refined = world.refined_cell(macro_coord).expect("refined cell");
    assert_eq!(refined.occupied_slot_count(), 1);
}

#[test]
fn builtin_prefabs_match_web_resolution_and_smoke_counts() {
    let registry = LocalPrefabRegistry::with_builtins();

    let sphere = registry.get("builtin_sphere").expect("sphere prefab");
    let cylinder = registry.get("builtin_cylinder").expect("cylinder prefab");
    let stairs = registry.get("builtin_stairs").expect("stairs prefab");

    assert_eq!(sphere.definition.micro_resolution, MICRO_PER_MACRO);
    assert_eq!(cylinder.definition.micro_resolution, MICRO_PER_MACRO);
    assert_eq!(stairs.definition.micro_resolution, MICRO_PER_MACRO);
    assert_eq!(sphere.total_occupied_slots(), 280);
    assert_eq!(cylinder.total_occupied_slots(), 416);
    assert!(stairs.total_occupied_slots() > 0);
}

#[test]
fn world_edit_hotbar_and_snapshot_round_trip_match_web_cli_contract() {
    let mut world = VoxelWorld::new();
    world.bootstrap_showcase(1);

    assert!(world.place_block(MacroCoord::new(0, 4, 0), block(VoxelMaterialId::Dirt)));
    assert!(!world.place_block(MacroCoord::new(0, 4, 0), block(VoxelMaterialId::Stone)));
    assert!(world.break_block(MacroCoord::new(0, 4, 0)));

    world.select_hotbar_index(4).expect("hotbar 5");
    assert_eq!(world.hotbar().selected.kind, HotbarEntryKind::Prefab);
    assert_eq!(world.hotbar().selected.label, "sphere");

    let placed = world.place_prefab("builtin_sphere", MacroCoord::new(8, 5, 8), Rotation::Rot0);
    assert!(placed.ok);
    assert_eq!(placed.placed, 1);
    assert!(
        world
            .micro_block(MacroCoord::new(8, 5, 8), MicroCoord::new(4, 4, 4))
            .is_some()
    );

    let exported = world.export_snapshot();
    let imported = VoxelWorld::from_snapshot(exported).expect("snapshot import");
    assert_eq!(imported.total_solid_cells(), world.total_solid_cells());
    assert_eq!(
        imported
            .micro_block(MacroCoord::new(8, 5, 8), MicroCoord::new(4, 4, 4))
            .map(|block| block.material_id),
        Some(VoxelMaterialId::Wood)
    );
}

#[test]
fn boundary_snap_uses_micro_overlap_and_contact_rules() {
    let mut world = VoxelWorld::new();
    assert!(world.place_block(MacroCoord::new(2, 4, 2), block(VoxelMaterialId::Stone)));

    let request = BoundarySnapRequest {
        prefab_name: "builtin_sphere".to_string(),
        hit_macro: MacroCoord::new(2, 4, 2),
        face_normal: MacroCoord::new(1, 0, 0),
        rotation: Rotation::Rot0,
    };

    let preview = world.preview_prefab_boundary_snap(&request);
    assert!(preview.ok);
    assert_eq!(preview.overlap_slots, 0);
    assert!(preview.contact_slots > 0);

    let placed = world.place_prefab_boundary_snap(&request);
    assert!(placed.ok);

    let rejected = world.place_prefab_boundary_snap(&request);
    assert!(!rejected.ok);
    assert!(rejected.conflict);
}

// Audit D-M3: parity tests for the three previously-uncovered web-vs-bevy
// behaviours — refined cell multi-coord tracking, prefab boundary-snap
// rejection on overlap, and multi-prefab snapshot round-trip identity.

#[test]
fn refined_cell_tracks_multiple_micro_blocks_and_overwrite_is_idempotent() {
    let mut world = VoxelWorld::new();
    let macro_coord = MacroCoord::new(2, 4, 2);

    let coords = [
        MicroCoord::new(0, 0, 0),
        MicroCoord::new(7, 7, 7),
        MicroCoord::new(4, 4, 4),
        MicroCoord::new(0, 0, 7),
        MicroCoord::new(7, 0, 0),
    ];
    for coord in coords {
        assert!(world.set_micro_block(macro_coord, coord, block(VoxelMaterialId::Stone)));
    }

    let refined = world
        .refined_cell(macro_coord)
        .expect("refined cell after multi-coord placement");
    assert_eq!(refined.occupied_slot_count() as usize, coords.len());

    // Overwriting an already-occupied slot must not double-count and the
    // refined material reflects the latest write.
    assert!(world.set_micro_block(macro_coord, coords[0], block(VoxelMaterialId::Wood)));
    let refined = world
        .refined_cell(macro_coord)
        .expect("refined cell after overwrite");
    assert_eq!(refined.occupied_slot_count() as usize, coords.len());
    assert_eq!(
        world
            .micro_block(macro_coord, coords[0])
            .map(|b| b.material_id),
        Some(VoxelMaterialId::Wood)
    );
}

#[test]
fn place_prefab_boundary_snap_rejects_when_overlap_slots_present() {
    let mut world = VoxelWorld::new();
    // Place a base macro block that the snapped prefab will lean against.
    assert!(world.place_block(MacroCoord::new(2, 4, 2), block(VoxelMaterialId::Stone)));

    // First snap place succeeds (no overlap, contact slots present).
    let request = BoundarySnapRequest {
        prefab_name: "builtin_sphere".to_string(),
        hit_macro: MacroCoord::new(2, 4, 2),
        face_normal: MacroCoord::new(1, 0, 0),
        rotation: Rotation::Rot0,
    };
    let placed = world.place_prefab_boundary_snap(&request);
    assert!(placed.ok, "first snap place must succeed");
    assert!(placed.instance_id.is_some());

    // Second snap place at the same request now overlaps the freshly-placed
    // sphere and must be rejected with conflict=true. preview must agree.
    let preview = world.preview_prefab_boundary_snap(&request);
    assert!(!preview.ok, "preview must reject overlap");
    assert!(preview.overlap_slots > 0);
    let rerun = world.place_prefab_boundary_snap(&request);
    assert!(!rerun.ok);
    assert!(rerun.conflict);
    assert!(rerun.instance_id.is_none());
}

#[test]
fn batch_import_preserves_multiple_prefab_placements() {
    let mut world = VoxelWorld::new();
    world.bootstrap_showcase(1);

    // Place two distinct prefabs at distinct macro origins. Recording the
    // placement results lets us assert every per-prefab fact survives a
    // snapshot round-trip.
    let sphere = world.place_prefab("builtin_sphere", MacroCoord::new(8, 5, 8), Rotation::Rot0);
    assert!(sphere.ok);
    assert!(sphere.placed > 0);
    let sphere_instance = sphere.instance_id.expect("sphere instance id");

    let cylinder = world.place_prefab(
        "builtin_cylinder",
        MacroCoord::new(16, 5, 16),
        Rotation::Rot0,
    );
    assert!(cylinder.ok);
    assert!(cylinder.placed > 0);
    let cylinder_instance = cylinder.instance_id.expect("cylinder instance id");
    assert_ne!(sphere_instance, cylinder_instance);

    let total_before = world.total_solid_cells();
    assert!(total_before > 0);

    let exported = world.export_snapshot();
    let imported = VoxelWorld::from_snapshot(exported).expect("snapshot import must succeed");
    assert_eq!(imported.total_solid_cells(), total_before);

    // Both prefab core cells should still be present after the round-trip.
    assert!(
        imported
            .micro_block(MacroCoord::new(8, 5, 8), MicroCoord::new(4, 4, 4))
            .is_some(),
        "sphere center must survive import"
    );
    assert!(
        imported
            .micro_block(MacroCoord::new(16, 5, 16), MicroCoord::new(4, 4, 4))
            .is_some(),
        "cylinder center must survive import"
    );
}
