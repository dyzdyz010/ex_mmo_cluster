use bevy_client::voxel::{
    MacroCoord, MicroCoord, VoxelCliCommand, VoxelMaterialId, VoxelWorld,
    execute_voxel_cli_command, parse_voxel_cli_command,
};

#[test]
fn parses_web_style_voxel_cli_commands() {
    assert_eq!(
        parse_voxel_cli_command("place 1 2 3 wood").unwrap(),
        Some(VoxelCliCommand::Place {
            coord: MacroCoord::new(1, 2, 3),
            material: Some(VoxelMaterialId::Wood),
        })
    );
    assert_eq!(
        parse_voxel_cli_command("micro_cell 1 2 3 4 5 6").unwrap(),
        Some(VoxelCliCommand::MicroCell {
            macro_coord: MacroCoord::new(1, 2, 3),
            micro: MicroCoord::new(4, 5, 6),
        })
    );
    assert_eq!(
        parse_voxel_cli_command("prefab_place builtin_sphere 8 5 8 rot90").unwrap(),
        Some(VoxelCliCommand::PrefabPlace {
            name: "builtin_sphere".to_string(),
            origin: MacroCoord::new(8, 5, 8),
            rotation: bevy_client::voxel::Rotation::Rot90,
        })
    );
}

#[test]
fn executes_voxel_cli_commands_with_structured_results() {
    let mut world = VoxelWorld::new();

    let place = execute_voxel_cli_command(
        &mut world,
        VoxelCliCommand::Place {
            coord: MacroCoord::new(1, 2, 3),
            material: Some(VoxelMaterialId::Ice),
        },
        None,
    );
    assert!(place.ok);
    assert_eq!(place.event, "place");
    assert_eq!(place.field("coord"), Some("1,2,3"));
    assert_eq!(place.field("material"), Some("ice"));

    let cell = execute_voxel_cli_command(
        &mut world,
        VoxelCliCommand::Cell {
            coord: MacroCoord::new(1, 2, 3),
        },
        None,
    );
    assert!(cell.ok);
    assert_eq!(cell.field("mode"), Some("normal"));

    let exported = execute_voxel_cli_command(&mut world, VoxelCliCommand::WorldExport, None);
    assert!(exported.ok);
    let json = exported.field("json").expect("json");

    let mut imported = VoxelWorld::new();
    let imported_result = execute_voxel_cli_command(
        &mut imported,
        VoxelCliCommand::WorldImport {
            json: json.to_string(),
        },
        None,
    );
    assert!(imported_result.ok);
    assert_eq!(imported.total_solid_cells(), 1);
}
