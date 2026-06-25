//! `scene` — the shared 3D world environment and render-asset construction.
//!
//! Owns what is conceptually "the stage" rather than any one gameplay domain:
//! the sun + atmospheric-scattering planet, and the shared
//! [`SceneRenderAssets`](crate::app::SceneRenderAssets) mesh/material handles
//! consumed by the actor (`presentation`) and voxel renderers.
//!
//! 架构重整阶段3:从 `app::setup` 巨函数拆出。`SceneEnvironmentPlugin` spawns the
//! world environment on `Startup`; the render-asset handles are built once at the
//! composition root ([`build_scene_render_assets`]) so every domain `Startup`
//! system can read `Res<SceneRenderAssets>` without a startup-ordering hazard.

use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::light::atmosphere::ScatteringMedium;
use bevy::light::{Atmosphere, AtmosphereEnvironmentMapLight, light_consts::lux};
use bevy::camera::Exposure;
use bevy::pbr::AtmosphereSettings;
use bevy::post_process::bloom::Bloom;
use bevy::prelude::*;

use crate::app::SceneRenderAssets;
use crate::camera::{MainCamera, OrbitCameraState, camera_transform_from_orbit};
use crate::voxel::{VoxelMaterialId, plugin::voxel_material_color};

/// World stage: the sun, the atmosphere planet, and the main camera.
pub struct SceneEnvironmentPlugin;

impl Plugin for SceneEnvironmentPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, spawn_world_environment);
    }
}

/// Builds the shared mesh + material handles once, from the composition root.
///
/// Built at root (not in a `Startup` system) so the resource exists before ANY
/// `Startup` system runs — the voxel target-marker spawn and the per-frame
/// presentation/voxel renderers read `Res<SceneRenderAssets>` with no ordering
/// dependency to manage.
pub(crate) fn build_scene_render_assets(world: &mut World) -> SceneRenderAssets {
    let (cube_mesh, player_mesh, target_mesh) = {
        let mut meshes = world.resource_mut::<Assets<Mesh>>();
        (
            meshes.add(Cuboid::new(1.0, 1.0, 1.0)),
            meshes.add(Cuboid::new(1.0, 1.0, 1.0)),
            meshes.add(Cuboid::new(1.0, 1.0, 1.0)),
        )
    };
    let mut materials = world.resource_mut::<Assets<StandardMaterial>>();
    SceneRenderAssets {
        cube_mesh,
        player_mesh,
        target_mesh,
        dirt_material: materials.add(StandardMaterial {
            base_color: voxel_material_color(VoxelMaterialId::Dirt),
            perceptual_roughness: 0.9,
            ..default()
        }),
        stone_material: materials.add(StandardMaterial {
            base_color: voxel_material_color(VoxelMaterialId::Stone),
            perceptual_roughness: 0.95,
            ..default()
        }),
        wood_material: materials.add(StandardMaterial {
            base_color: voxel_material_color(VoxelMaterialId::Wood),
            perceptual_roughness: 0.86,
            ..default()
        }),
        ice_material: materials.add(StandardMaterial {
            base_color: voxel_material_color(VoxelMaterialId::Ice),
            perceptual_roughness: 0.38,
            metallic: 0.02,
            ..default()
        }),
        // GUI-smoke 2026-04-26 follow-up: brighter base + much stronger
        // emissive so the local actor is unmistakable against an empty
        // (no-voxel) background and against neighbouring NPC/player cubes.
        local_player_material: materials.add(StandardMaterial {
            base_color: Color::srgb(0.30, 1.00, 0.50),
            emissive: Color::srgb(0.20, 1.20, 0.40).into(),
            perceptual_roughness: 0.4,
            ..default()
        }),
        remote_player_material: materials.add(Color::srgb(0.3, 0.65, 1.0)),
        moving_player_material: materials.add(Color::srgb(0.35, 0.75, 1.0)),
        selected_actor_material: materials.add(Color::srgb(1.0, 0.95, 0.35)),
        npc_material: materials.add(Color::srgb(0.95, 0.45, 0.35)),
        target_material: materials.add(StandardMaterial {
            base_color: Color::srgba(0.95, 0.35, 0.95, 0.82),
            alpha_mode: AlphaMode::Blend,
            unlit: true,
            ..default()
        }),
    }
}

fn spawn_world_environment(
    mut commands: Commands,
    mut scattering_mediums: ResMut<Assets<ScatteringMedium>>,
) {
    // Sun. `lux::RAW_SUNLIGHT` is the raw extra-atmospheric value the
    // `Atmosphere` post-process expects as input — it then attenuates and
    // tints the light per ray through the medium, so the ground sees the
    // "post-scattering" colour automatically.
    commands.spawn((
        DirectionalLight {
            illuminance: lux::RAW_SUNLIGHT,
            shadow_maps_enabled: true,
            ..default()
        },
        Transform::from_xyz(1.0, 0.6, 0.3).looking_at(Vec3::ZERO, Vec3::Y),
    ));

    // The atmosphere "planet". Bevy 0.19 moved `Atmosphere` OFF the camera onto a
    // world entity whose `GlobalTransform` IS the planet center (bevy_light
    // atmosphere.rs: "The entity's GlobalTransform is the planet center in world
    // space"). Placing the planet center at -inner_radius on Y puts the world
    // ground plane (Y=0) at the planet surface, so a camera at world height h
    // renders as altitude h. (If `Atmosphere` sits on the camera — the pre-0.19
    // idiom — the camera maps to the atmosphere origin → r≈0 → degenerate up → the
    // sky renders BLACK toward the zenith.)
    const EARTH_INNER_RADIUS: f32 = 6_360_000.0;
    commands.spawn((
        Atmosphere::earth(scattering_mediums.add(ScatteringMedium::default())),
        Transform::from_xyz(0.0, -EARTH_INNER_RADIUS, 0.0),
    ));

    // Camera with procedural atmospheric scattering (Hillaire 2020). HDR is
    // auto-required by atmosphere rendering; tonemapping + exposure bring
    // `lux::RAW_SUNLIGHT` (~120k lx) back into a viewable range.
    // `AtmosphereEnvironmentMapLight` lets the sky drive ambient IBL so
    // shadowed surfaces aren't pitch black without the old PointLight.
    commands.spawn((
        Camera3d::default(),
        MainCamera,
        camera_transform_from_orbit(&OrbitCameraState::default()),
        AtmosphereSettings::default(),
        AtmosphereEnvironmentMapLight::default(),
        Exposure { ev100: 13.0 },
        Tonemapping::AcesFitted,
        Bloom::NATURAL,
    ));
}
