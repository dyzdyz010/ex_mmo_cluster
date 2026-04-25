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
