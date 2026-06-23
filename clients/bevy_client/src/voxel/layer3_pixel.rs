//! Layer-3 GPU pixel verification (feature `layer3`, GPU required).
//!
//! Renders the REAL voxel meshes + materials off-screen on the local GPU and
//! reads the framebuffer back to assert rendering properties that the CPU
//! mesh/data tests structurally CANNOT — chiefly that the field overlay's
//! depth-disable material (`FieldDepthDisable` extension, the #6 fix) renders
//! THROUGH opaque terrain, which is a GPU pipeline-state property, not mesh data.
//!
//! Gating: behind the `layer3` cargo feature so normal `cargo test` needs no GPU.
//! Run with `cargo test --features layer3 layer3_pixel -- --test-threads=1`
//! (locally with a GPU, or in the lavapipe CI job).
//!
//! MUST be single-threaded: each test spins a full Bevy render App with its own
//! GPU device, and cargo's default parallel runner would create one Vulkan device
//! per test thread at once — enough concurrent devices to exhaust the driver, so a
//! few Apps render nothing (readback returns the bare clear color) and flake. This
//! is device contention, NOT a rendering bug: every test passes alone and the full
//! suite passes green with `--test-threads=1`.
//!
//! Robustness: assertions check CHANNEL RELATIONSHIPS (red-dominance,
//! neutral-gray, not-clear), never exact RGB — so lavapipe-vs-real-GPU
//! brightness/sRGB/tonemap differences don't flake them. Tonemapping is disabled
//! on the off-screen camera so the readback is a near-direct function of shading.

use bevy::camera::RenderTarget;
use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::ecs::observer::On;
use bevy::pbr::MaterialPlugin;
use bevy::prelude::*;
use bevy::render::gpu_readback::{Readback, ReadbackComplete};
use bevy::render::render_resource::{TextureFormat, TextureUsages};
use bevy::window::{ExitCondition, WindowPlugin};
use bevy::winit::WinitPlugin;

use crate::login::AppState;
use crate::voxel::authority::{AuthorityChunk, CellState};
use crate::voxel::debris::{
    DEFAULT_PARTICLE_SIZE_M, DebrisConfig, DebrisKind, DebrisSimulation, DebrisSpawnPoint,
};
use crate::voxel::chunk_render::{
    build_decal_mesh, build_mesh, build_mesh_with_colors, material_color, mosaic_block_texture,
};
use crate::voxel::field_render::{FieldOverlayMaterial, field_overlay_material};
use crate::voxel::field_view::{FieldOverlayKind, field_color, overlay_mesh};
use crate::voxel::mesher::{
    ChunkNeighbors, chunk_render_mesh, chunk_render_mesh_lit, greedy_mesh_chunk,
};
use crate::voxel::skylight::{Skylight, SkylightConfig};
use crate::voxel::surface_decal::surface_decal_mesh;
use crate::voxel::wire::{
    FIELD_MASK_ELECTRIC_CURRENT, FIELD_MASK_ELECTRIC_POTENTIAL, FIELD_MASK_IONIZATION,
    FIELD_MASK_LIGHT, FIELD_MASK_LIGHT_COLOR, FIELD_MASK_TEMPERATURE, FieldRegionSnapshot,
    MaskWords, MicroLayer, NormalBlock, RefinedCell, SurfaceElement, VoxelServerMessage,
};
use crate::voxel::{HeatSmokePlugin, IncandescencePlugin, LightningPlugin, VoxelAuthority};

/// Framebuffer size. Width divisible by 64 → RGBA8 row bytes (W*4) divisible by
/// 256 → no GPU row padding to de-pad on readback. 512 keeps the assertion tests
/// valid (all sampling is center-relative `W/2,H/2` or centroid-based) while giving
/// the showcase renders a presentable resolution.
const W: u32 = 512;
const H: u32 = 512;
const MACRO: f32 = 100.0; // MACRO_RENDER_SIZE

/// Distinct dark-green clear color: neither gray (terrain) nor red (overlay), so
/// a miss reads green, wall-only reads gray, a through-terrain pass reads red.
fn clear_color() -> Color {
    Color::srgb(0.05, 0.30, 0.10)
}

#[derive(Resource, Default)]
struct Captured(Option<Vec<u8>>);

/// One sampled pixel as linear-ish 0..1 RGBA (from the u8 readback).
#[derive(Clone, Copy, Debug)]
struct Px {
    r: f32,
    g: f32,
    b: f32,
    #[allow(dead_code)]
    a: f32,
}

/// Per-channel median of a `2k+1` square patch centered at (cx, cy) — robust to
/// edge anti-aliasing and half-pixel projection error.
fn sample_patch(data: &[u8], cx: u32, cy: u32, k: u32) -> Px {
    let (mut rs, mut gs, mut bs, mut as_) = (vec![], vec![], vec![], vec![]);
    for dy in -(k as i32)..=(k as i32) {
        for dx in -(k as i32)..=(k as i32) {
            let x = cx as i32 + dx;
            let y = cy as i32 + dy;
            if x < 0 || y < 0 || x >= W as i32 || y >= H as i32 {
                continue;
            }
            let i = ((y as u32 * W + x as u32) * 4) as usize;
            rs.push(data[i]);
            gs.push(data[i + 1]);
            bs.push(data[i + 2]);
            as_.push(data[i + 3]);
        }
    }
    let median = |mut v: Vec<u8>| {
        v.sort_unstable();
        v[v.len() / 2] as f32 / 255.0
    };
    Px {
        r: median(rs),
        g: median(gs),
        b: median(bs),
        a: median(as_),
    }
}

/// Renders a scene off-screen and returns the RGBA8 framebuffer bytes (W*H*4).
/// `build` spawns the camera (targeting `image`), light, and scene entities.
fn render_scene(build: impl FnOnce(&mut World, Handle<Image>)) -> Vec<u8> {
    let mut app = App::new();
    app.add_plugins(
        DefaultPlugins
            .set(WindowPlugin {
                primary_window: None,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .disable::<WinitPlugin>(),
    )
    .add_plugins(MaterialPlugin::<FieldOverlayMaterial>::default())
    .init_resource::<Captured>();

    let image = {
        let mut images = app.world_mut().resource_mut::<Assets<Image>>();
        let mut img = Image::new_target_texture(W, H, TextureFormat::Rgba8UnormSrgb, None);
        img.texture_descriptor.usage |= TextureUsages::COPY_SRC;
        images.add(img)
    };

    // Read the rendered texture back each frame; capture the first completion.
    app.world_mut()
        .spawn(Readback::texture(image.clone()))
        // Overwrite each frame so we keep the LATEST readback (the first one can
        // land before the camera has rendered → all zeros).
        .observe(
            |event: On<ReadbackComplete>, mut captured: ResMut<Captured>| {
                captured.0 = Some(event.data.clone());
            },
        );

    build(app.world_mut(), image.clone());

    // Drive plugin finish/cleanup ourselves (we loop `update`, not `run`): the
    // render device is created in RenderPlugin::finish, so without this the
    // RenderApp systems see no `RenderDevice`.
    app.finish();
    app.cleanup();
    pump_until_rendered(&mut app)
}

/// Pumps frames until a post-render readback lands with actual geometry (more
/// than just the clear color), retrying in rounds. Running many full render Apps
/// in one process can occasionally leave a later App's first frames producing no
/// geometry (GPU resource pressure); a couple of extra rounds recovers it, so the
/// suite isn't flaky. Returns the RGBA8 framebuffer bytes.
fn pump_until_rendered(app: &mut App) -> Vec<u8> {
    let clear = clear_color().to_srgba();
    for _round in 0..4 {
        for _ in 0..16 {
            app.update();
        }
        let data = app.world().resource::<Captured>().0.clone();
        if let Some(data) = data {
            // Count pixels that differ from the clear color (i.e. real geometry).
            let mut rendered = 0u32;
            for px in data.chunks_exact(4) {
                let d = (px[0] as f32 / 255.0 - clear.red).abs()
                    + (px[1] as f32 / 255.0 - clear.green).abs()
                    + (px[2] as f32 / 255.0 - clear.blue).abs();
                if d > 0.06 {
                    rendered += 1;
                }
            }
            if rendered > 30 {
                return data;
            }
        }
    }
    // Last resort: return whatever we have (the assertion will report it).
    app.world()
        .resource::<Captured>()
        .0
        .clone()
        .expect("gpu readback never completed (no adapter? render failed?)")
}

// ---- scene building blocks --------------------------------------------------

fn stone(material_id: u16) -> CellState {
    CellState::Solid(NormalBlock {
        material_id,
        state_flags: 0,
        health: 0,
        temperature_delta: 0,
        moisture_delta: 0,
        attribute_set_ref: 0,
        tag_set_ref: 0,
    })
}

/// A 16³ chunk with `solid_cells` (local macro coords) set to stone (id 2).
fn wall_chunk(solid_cells: &[(i32, i32, i32)]) -> AuthorityChunk {
    material_chunk(2, solid_cells)
}

/// A 16³ chunk with `solid_cells` set to a solid block of `material_id`.
fn material_chunk(material_id: u16, solid_cells: &[(i32, i32, i32)]) -> AuthorityChunk {
    let size = 16usize;
    let mut cells = vec![CellState::Empty; size * size * size];
    for &(x, y, z) in solid_cells {
        let idx = (x + y * size as i32 + z * size as i32 * size as i32) as usize;
        cells[idx] = stone(material_id);
    }
    AuthorityChunk {
        chunk_version: 1,
        chunk_size_in_macro: size as u8,
        cells,
        ..Default::default()
    }
}

fn temperature_field(
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
        light: vec![],
        light_color: vec![],
    }
}

/// Spawns a camera at `eye` looking at `look`, targeting `image`, tonemapping off.
fn spawn_camera(world: &mut World, image: Handle<Image>, eye: Vec3, look: Vec3) {
    world.spawn((
        Camera3d::default(),
        Camera {
            clear_color: ClearColorConfig::Custom(clear_color()),
            ..default()
        },
        // RenderTarget is its own component in 0.18 (not a Camera field).
        RenderTarget::Image(image.into()),
        Tonemapping::None,
        // Per-camera ambient so lit terrain renders as visible (neutral) gray;
        // the assertions only need non-black + roughly-neutral channels.
        AmbientLight {
            color: Color::WHITE,
            brightness: 6000.0,
            ..default()
        },
        Transform::from_translation(eye).looking_at(look, Vec3::Y),
    ));
}

/// A 16³ chunk with a single fully-solid REFINED stone cell at `at` — exercises
/// the refined micro-mesh render path (8³ occupancy shell), not the greedy path.
fn refined_stone_chunk(at: (i32, i32, i32)) -> AuthorityChunk {
    let size = 16usize;
    let mut cells = vec![CellState::Empty; size * size * size];
    let full: MaskWords = [u64::MAX; 8]; // all 512 micro slots occupied
    let layer = MicroLayer {
        mask_words: full,
        material_id: 2, // stone
        state_flags: 0,
        health: 0,
        attribute_set_ref: 0,
        tag_set_ref: 0,
        owner_object_id: 0,
        owner_part_id: 0,
    };
    let refined = RefinedCell {
        occupancy_words: full,
        boundary_cache: 0,
        layers: vec![layer],
        object_refs: vec![],
    };
    let idx = (at.0 + at.1 * size as i32 + at.2 * size as i32 * size as i32) as usize;
    cells[idx] = CellState::Refined(refined);
    AuthorityChunk {
        chunk_version: 1,
        chunk_size_in_macro: size as u8,
        cells,
        ..Default::default()
    }
}

/// Spawns a chunk via the FULL render path (`chunk_render_mesh` = greedy solid +
/// per-refined micro mesh), lit white material — exercises the real mesh path.
fn spawn_chunk_render(world: &mut World, chunk: &AuthorityChunk) {
    let mesh = build_mesh(&chunk_render_mesh(chunk, MACRO, &ChunkNeighbors::default()));
    let mesh_handle = world.resource_mut::<Assets<Mesh>>().add(mesh);
    let material = world
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::WHITE,
            perceptual_roughness: 0.9,
            ..default()
        });
    world.spawn((
        Mesh3d(mesh_handle),
        MeshMaterial3d(material),
        Transform::from_translation(Vec3::ZERO),
    ));
}

/// A chunk with a solid host cell at `host` carrying a surface element on `face`
/// (ordinal x_neg=0..z_pos=5) of `surface_type_id` — for the decal render path.
fn decal_chunk(host: (i32, i32, i32), face: u8, surface_type_id: u16) -> AuthorityChunk {
    let mut chunk = wall_chunk(&[host]);
    let macro_index = (host.0 + host.1 * 16 + host.2 * 256) as u16;
    chunk.surface_elements = vec![SurfaceElement {
        macro_index,
        face,
        surface_type_id,
        attribute_set_ref: 0,
        tag_set_ref: 0,
        owner_actor_id: 0,
    }];
    chunk
}

/// Spawns ONLY the surface-element decal mesh (real `surface_decal_mesh` +
/// `build_decal_mesh`, decal colors baked per-vertex), lit white material.
fn spawn_decal(world: &mut World, chunk: &AuthorityChunk) {
    let data = surface_decal_mesh(chunk, MACRO);
    assert!(!data.is_empty(), "decal produced no geometry");
    let mesh_handle = world
        .resource_mut::<Assets<Mesh>>()
        .add(build_decal_mesh(&data));
    let material = world
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::WHITE,
            perceptual_roughness: 0.9,
            ..default()
        });
    world.spawn((
        Mesh3d(mesh_handle),
        MeshMaterial3d(material),
        Transform::from_translation(Vec3::ZERO),
    ));
}

/// Spawns the stone wall chunk mesh (real mesher + lit white material).
fn spawn_wall(world: &mut World, chunk: &AuthorityChunk) {
    let mesh = build_mesh(&greedy_mesh_chunk(chunk, MACRO));
    let mesh_handle = world.resource_mut::<Assets<Mesh>>().add(mesh);
    let material = world
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::WHITE,
            perceptual_roughness: 0.9,
            ..default()
        });
    world.spawn((
        Mesh3d(mesh_handle),
        MeshMaterial3d(material),
        Transform::from_translation(Vec3::ZERO), // chunk (0,0,0)
    ));
}

/// Spawns a temperature overlay mesh with the REAL depth-disable material.
fn spawn_overlay(world: &mut World, field: &FieldRegionSnapshot) {
    spawn_overlay_kind(world, field, FieldOverlayKind::Temperature);
}

/// Builds an ionization field snapshot (u8 0..255) for the plasma overlay test.
fn ionization_field(
    region_id: u64,
    chunk_coord: [i32; 3],
    cells: &[(u16, u8)],
) -> FieldRegionSnapshot {
    FieldRegionSnapshot {
        logical_scene_id: 1,
        chunk_coord,
        region_id,
        tick_count: 1,
        field_mask: FIELD_MASK_IONIZATION,
        macro_indices: cells.iter().map(|(i, _)| *i).collect(),
        temperature: vec![],
        electric_potential: vec![],
        electric_current: vec![],
        ionization: cells.iter().map(|(_, v)| *v).collect(),
        light: vec![],
        light_color: vec![],
    }
}

/// A light field snapshot (u8 0..255 per cell) for the light-overlay pixel test.
fn light_field(region_id: u64, chunk_coord: [i32; 3], cells: &[(u16, u8)]) -> FieldRegionSnapshot {
    FieldRegionSnapshot {
        logical_scene_id: 1,
        chunk_coord,
        region_id,
        tick_count: 1,
        field_mask: FIELD_MASK_LIGHT,
        macro_indices: cells.iter().map(|(i, _)| *i).collect(),
        temperature: vec![],
        electric_potential: vec![],
        electric_current: vec![],
        ionization: vec![],
        light: cells.iter().map(|(_, v)| *v).collect(),
        light_color: vec![],
    }
}

/// A colored light field (intensity + packed RGB888 per cell) for the colored-light
/// overlay pixel test.
fn colored_light_field(
    region_id: u64,
    chunk_coord: [i32; 3],
    cells: &[(u16, u8, u32)],
) -> FieldRegionSnapshot {
    FieldRegionSnapshot {
        logical_scene_id: 1,
        chunk_coord,
        region_id,
        tick_count: 1,
        field_mask: FIELD_MASK_LIGHT | FIELD_MASK_LIGHT_COLOR,
        macro_indices: cells.iter().map(|(i, _, _)| *i).collect(),
        temperature: vec![],
        electric_potential: vec![],
        electric_current: vec![],
        ionization: vec![],
        light: cells.iter().map(|(_, v, _)| *v).collect(),
        light_color: cells.iter().map(|(_, _, c)| *c).collect(),
    }
}

/// Spawns the given field overlay kind with the REAL depth-disable material.
fn spawn_overlay_kind(world: &mut World, field: &FieldRegionSnapshot, kind: FieldOverlayKind) {
    let data = overlay_mesh(field, kind, MACRO);
    assert!(
        !data.is_empty(),
        "overlay produced no geometry for {kind:?}"
    );
    let mesh_handle = world
        .resource_mut::<Assets<Mesh>>()
        .add(build_mesh_with_colors(&data, field_color));
    let material = world
        .resource_mut::<Assets<FieldOverlayMaterial>>()
        .add(field_overlay_material());
    world.spawn((
        Mesh3d(mesh_handle),
        MeshMaterial3d(material),
        Transform::from_translation(Vec3::ZERO),
    ));
}

/// Builds an electric field snapshot (potential and/or current) for overlay tests.
fn electric_field(
    region_id: u64,
    chunk_coord: [i32; 3],
    mask: u8,
    cells: &[(u16, f32)],
) -> FieldRegionSnapshot {
    let macro_indices: Vec<u16> = cells.iter().map(|(i, _)| *i).collect();
    let values: Vec<f32> = cells.iter().map(|(_, v)| *v).collect();
    let is_current = mask & FIELD_MASK_ELECTRIC_CURRENT != 0;
    FieldRegionSnapshot {
        logical_scene_id: 1,
        chunk_coord,
        region_id,
        tick_count: 1,
        field_mask: mask,
        macro_indices,
        temperature: vec![],
        electric_potential: if is_current { vec![] } else { values.clone() },
        electric_current: if is_current { values } else { vec![] },
        ionization: vec![],
        light: vec![],
        light_color: vec![],
    }
}

/// Spawns a temperature overlay with a PLAIN alpha-blended material (NO
/// depth-disable extension) — the negative control for the through-terrain test.
fn spawn_overlay_no_depth_disable(world: &mut World, field: &FieldRegionSnapshot) {
    let data = overlay_mesh(field, FieldOverlayKind::Temperature, MACRO);
    let mesh_handle = world
        .resource_mut::<Assets<Mesh>>()
        .add(build_mesh_with_colors(&data, field_color));
    let material = world
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::WHITE,
            unlit: true,
            alpha_mode: AlphaMode::Blend,
            ..default()
        });
    world.spawn((
        Mesh3d(mesh_handle),
        MeshMaterial3d(material),
        Transform::from_translation(Vec3::ZERO),
    ));
}

// Macro index of local (1,1,z): 1 + 1*16 + z*256.
fn idx(x: u16, y: u16, z: u16) -> u16 {
    x + y * 16 + z * 256
}

/// Renders a scene driven by the REAL `HeatSmokePlugin`: enqueues an electric
/// field snapshot into the authority, drains it (surfacing the smoke event), and
/// lets the adapter's spawn + render systems run — proving the heat-smoke
/// particle layer actually rasterizes on screen (emergence visible), end to end.
fn render_with_heat_smoke(field: &FieldRegionSnapshot, eye: Vec3, look: Vec3) -> Vec<u8> {
    let mut app = App::new();
    app.add_plugins(
        DefaultPlugins
            .set(WindowPlugin {
                primary_window: None,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .disable::<WinitPlugin>(),
    )
    .add_plugins(HeatSmokePlugin)
    .insert_state(AppState::Game)
    .init_resource::<VoxelAuthority>()
    .init_resource::<Captured>();
    // The adapter systems live in ClientSet::Logic/Render; configure that ordering
    // (as the real app does) so spawn (Logic) precedes render-sync (Render) and the
    // commanded entities exist before the render extraction.
    crate::app::schedule::configure_client_sets(&mut app);

    let image = {
        let mut images = app.world_mut().resource_mut::<Assets<Image>>();
        let mut img = Image::new_target_texture(W, H, TextureFormat::Rgba8UnormSrgb, None);
        img.texture_descriptor.usage |= TextureUsages::COPY_SRC;
        images.add(img)
    };

    spawn_camera(app.world_mut(), image.clone(), eye, look);
    app.world_mut()
        .spawn(Readback::texture(image.clone()))
        .observe(
            |event: On<ReadbackComplete>, mut captured: ResMut<Captured>| {
                captured.0 = Some(event.data.clone());
            },
        );

    // Drive the authority the way the net→ingest path does, surfacing the smoke
    // event before the adapter's spawn system runs.
    {
        let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
        authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(field.clone()));
        authority.drain_inbox();
    }

    app.finish();
    app.cleanup();
    pump_until_rendered(&mut app)
}

/// Renders a scene driven by the REAL `LightningPlugin`: re-surfaces a discharge
/// field snapshot EACH frame (so a fresh bolt is always alive — the 480ms bolt TTL
/// is short vs the ~64-frame pump) and lets the adapter infer + strike + render the
/// bolt — proving the lightning layer actually rasterizes on screen, end to end.
fn render_with_lightning(
    field: &FieldRegionSnapshot,
    setup: impl FnOnce(&mut World, Handle<Image>),
) -> Vec<u8> {
    let mut app = App::new();
    app.add_plugins(
        DefaultPlugins
            .set(WindowPlugin {
                primary_window: None,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .disable::<WinitPlugin>(),
    )
    .add_plugins(LightningPlugin)
    .insert_state(AppState::Game)
    .init_resource::<VoxelAuthority>()
    .init_resource::<Captured>();
    crate::app::schedule::configure_client_sets(&mut app);

    let image = {
        let mut images = app.world_mut().resource_mut::<Assets<Image>>();
        let mut img = Image::new_target_texture(W, H, TextureFormat::Rgba8UnormSrgb, None);
        img.texture_descriptor.usage |= TextureUsages::COPY_SRC;
        images.add(img)
    };

    setup(app.world_mut(), image.clone());
    app.world_mut()
        .spawn(Readback::texture(image.clone()))
        .observe(
            |event: On<ReadbackComplete>, mut captured: ResMut<Captured>| {
                captured.0 = Some(event.data.clone());
            },
        );

    app.finish();
    app.cleanup();

    // Re-strike each frame, then pump — so the captured post-render frame always
    // has a live bolt regardless of how many frames the readback takes to land.
    let clear = clear_color().to_srgba();
    for _round in 0..4 {
        for _ in 0..16 {
            {
                let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
                authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(field.clone()));
                authority.drain_inbox();
            }
            app.update();
        }
        if let Some(data) = app.world().resource::<Captured>().0.clone() {
            let mut rendered = 0u32;
            for px in data.chunks_exact(4) {
                let d = (px[0] as f32 / 255.0 - clear.red).abs()
                    + (px[1] as f32 / 255.0 - clear.green).abs()
                    + (px[2] as f32 / 255.0 - clear.blue).abs();
                if d > 0.06 {
                    rendered += 1;
                }
            }
            if rendered > 30 {
                return data;
            }
        }
    }
    app.world()
        .resource::<Captured>()
        .0
        .clone()
        .expect("gpu readback never completed (no adapter? render failed?)")
}

/// Renders a scene driven by the REAL `IncandescencePlugin`: ingests a temperature
/// field snapshot, drains it (marking the incandescence channel dirty), and lets
/// the glow adapter build the additive blackbody mesh — proving hot cells emit a
/// temperature-derived glow on screen (emergent optics), end to end.
fn render_with_incandescence(
    field: &FieldRegionSnapshot,
    setup: impl FnOnce(&mut World, Handle<Image>),
) -> Vec<u8> {
    let mut app = App::new();
    app.add_plugins(
        DefaultPlugins
            .set(WindowPlugin {
                primary_window: None,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .disable::<WinitPlugin>(),
    )
    // The glow reuses the FieldOverlayMaterial type; register its MaterialPlugin
    // (IncandescencePlugin doesn't, to avoid double-registration in the real app).
    .add_plugins(MaterialPlugin::<FieldOverlayMaterial>::default())
    .add_plugins(IncandescencePlugin)
    .insert_state(AppState::Game)
    .init_resource::<VoxelAuthority>()
    .init_resource::<Captured>();
    crate::app::schedule::configure_client_sets(&mut app);

    let image = {
        let mut images = app.world_mut().resource_mut::<Assets<Image>>();
        let mut img = Image::new_target_texture(W, H, TextureFormat::Rgba8UnormSrgb, None);
        img.texture_descriptor.usage |= TextureUsages::COPY_SRC;
        images.add(img)
    };

    setup(app.world_mut(), image.clone());
    app.world_mut()
        .spawn(Readback::texture(image.clone()))
        .observe(
            |event: On<ReadbackComplete>, mut captured: ResMut<Captured>| {
                captured.0 = Some(event.data.clone());
            },
        );

    // Surface the temperature snapshot (marks incandescence dirty) before the
    // adapter's render system runs; the glow entity then persists across frames.
    {
        let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
        authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(field.clone()));
        authority.drain_inbox();
    }

    app.finish();
    app.cleanup();
    pump_until_rendered(&mut app)
}

/// Scans the whole frame for glow pixels (differing from the dark-green clear) and
/// returns their median color at the cluster centroid (or the clear color if none).
fn glow_centroid(data: &[u8]) -> Px {
    let clear = clear_color().to_srgba();
    let mut non_clear = 0u32;
    let (mut sx, mut sy) = (0u64, 0u64);
    for y in 0..H {
        for x in 0..W {
            let i = ((y * W + x) * 4) as usize;
            let r = data[i] as f32 / 255.0;
            let g = data[i + 1] as f32 / 255.0;
            let b = data[i + 2] as f32 / 255.0;
            let d = (r - clear.red).abs() + (g - clear.green).abs() + (b - clear.blue).abs();
            if d > 0.06 {
                non_clear += 1;
                sx += x as u64;
                sy += y as u64;
            }
        }
    }
    if non_clear == 0 {
        return Px {
            r: clear.red,
            g: clear.green,
            b: clear.blue,
            a: 1.0,
        };
    }
    let (cx, cy) = (
        (sx / non_clear as u64) as u32,
        (sy / non_clear as u64) as u32,
    );
    sample_patch(data, cx, cy, 4)
}

/// A temperature field snapshot for the incandescence tests.
fn incandescence_temp_field(
    region_id: u64,
    chunk_coord: [i32; 3],
    cells: &[(u16, f32)],
) -> FieldRegionSnapshot {
    temperature_field(region_id, chunk_coord, cells)
}

/// A discharge field snapshot (potential gradient + ionized channel) that drives
/// `infer_strike` to arc a bolt between two macro cells.
fn discharge_field(
    region_id: u64,
    chunk_coord: [i32; 3],
    cells: &[(u16, f32, u8)],
) -> FieldRegionSnapshot {
    FieldRegionSnapshot {
        logical_scene_id: 1,
        chunk_coord,
        region_id,
        tick_count: 1,
        field_mask: FIELD_MASK_ELECTRIC_POTENTIAL | FIELD_MASK_IONIZATION,
        macro_indices: cells.iter().map(|(i, _, _)| *i).collect(),
        temperature: vec![],
        electric_potential: cells.iter().map(|(_, p, _)| *p).collect(),
        electric_current: vec![],
        ionization: cells.iter().map(|(_, _, ion)| *ion).collect(),
        light: vec![],
        light_color: vec![],
    }
}

// ---- tests ------------------------------------------------------------------

/// B (sanity): a solid stone chunk rasterizes to neutral-gray, non-clear pixels.
/// Catches frustum/winding/empty-mesh/material regressions in the core path.
#[test]
fn solid_chunk_rasterizes_to_neutral_gray() {
    // One solid stone cell at local (1,1,0); face center world (150,150,0).
    let chunk = wall_chunk(&[(1, 1, 0)]);
    let look = Vec3::new(150.0, 150.0, 50.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_wall(world, &chunk);
    });

    let center = sample_patch(&data, W / 2, H / 2, 3);
    // (a) geometry actually rasterized → not the dark-green clear color.
    let clear = clear_color().to_srgba();
    let off_clear = (center.r - clear.red).abs()
        + (center.g - clear.green).abs()
        + (center.b - clear.blue).abs();
    assert!(
        off_clear > 0.15,
        "center should be terrain, not clear color; got {center:?}"
    );
    // (b) neutral gray (equal channels) — stone palette came through, not magenta
    // (unknown-id fallback is R==B>>G) or a tint.
    let spread = (center.r - center.g)
        .abs()
        .max((center.r - center.b).abs())
        .max((center.g - center.b).abs());
    assert!(
        spread < 0.10,
        "stone should be neutral gray; got {center:?}"
    );
    assert!(
        center.r > 0.08,
        "lit stone should be non-black; got {center:?}"
    );
}

/// An UNKNOWN material id renders as the obvious magenta error color (R&B high,
/// green near-zero) — verifies the `material_color` unknown-id fallback reaches
/// the screen (so a real material-mapping bug shows loudly, not silently gray),
/// and that the vertex-color path renders a NON-gray color. Robust under any
/// lighting: the green channel of magenta [1,0,1] is 0 regardless of exposure.
#[test]
fn unknown_material_renders_magenta() {
    let chunk = material_chunk(9999, &[(1, 1, 0)]); // 9999 → unmapped → magenta
    let look = Vec3::new(150.0, 150.0, 50.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_wall(world, &chunk);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    assert!(
        c.r > c.g + 0.25 && c.b > c.g + 0.25,
        "unknown material should render magenta (red & blue >> green); got {c:?}"
    );
}

/// C (overlay color): an UNOBSTRUCTED hot overlay marker is red-dominant —
/// isolates the overlay color-ramp + alpha compositing from the depth concern.
#[test]
fn unobstructed_hot_overlay_is_red() {
    // Hot marker at local (1,1,1) center world (150,150,150); no wall.
    let field = temperature_field(1, [0, 0, 0], &[(idx(1, 1, 1), 10000.0)]);
    let look = Vec3::new(150.0, 150.0, 150.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_overlay(world, &field);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    assert!(
        c.r > c.g + 0.20 && c.r > c.b + 0.20,
        "unobstructed hot overlay should be red-dominant; got {c:?}"
    );
}

/// A (flagship): a hot overlay marker GEOMETRICALLY BEHIND an opaque stone wall
/// still shows red — proving the depth-disable material renders through terrain
/// (the #6 fix; impossible to cover with CPU mesh/data tests).
#[test]
fn overlay_renders_through_solid_wall() {
    // Wall: 3×3 solid slab at z=0 (covers the screen center). Marker: hot cell at
    // (1,1,1) center world (150,150,150) — BEHIND the wall (z=0 face) along +Z.
    let wall: Vec<(i32, i32, i32)> = (0..3)
        .flat_map(|x| (0..3).map(move |y| (x, y, 0)))
        .collect();
    let chunk = wall_chunk(&wall);
    let field = temperature_field(1, [0, 0, 0], &[(idx(1, 1, 1), 10000.0)]);
    let look = Vec3::new(150.0, 150.0, 150.0);

    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_wall(world, &chunk);
        spawn_overlay(world, &field);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    assert!(
        c.r > c.g + 0.20 && c.r > c.b + 0.20,
        "overlay must render THROUGH the wall (depth-disable); got {c:?} — \
         if this is neutral gray the marker was occluded (fix regressed)"
    );
}

/// A negative control: the IDENTICAL scene but with the overlay using a PLAIN
/// (non-depth-disable) material → the marker IS occluded by the wall → the center
/// is neutral gray, NOT red. Proves the positive test genuinely exercises
/// depth-disable (the marker is really behind the wall, not unobstructed).
#[test]
fn overlay_without_depth_disable_is_occluded_by_wall() {
    let wall: Vec<(i32, i32, i32)> = (0..3)
        .flat_map(|x| (0..3).map(move |y| (x, y, 0)))
        .collect();
    let chunk = wall_chunk(&wall);
    let field = temperature_field(1, [0, 0, 0], &[(idx(1, 1, 1), 10000.0)]);
    let look = Vec3::new(150.0, 150.0, 150.0);

    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_wall(world, &chunk);
        spawn_overlay_no_depth_disable(world, &field);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    // Occluded → we see the lit gray wall, not red.
    assert!(
        !(c.r > c.g + 0.20 && c.r > c.b + 0.20),
        "without depth-disable the marker must be occluded by the wall (gray, not red); got {c:?}"
    );
}

/// Cold temperature overlay is PURPLE (blue-dominant, green-lowest) — verifies the
/// cold branch of `temperature_color` ([0.55,0,1]) renders correctly, not just hot.
#[test]
fn cold_overlay_is_purple() {
    let field = temperature_field(1, [0, 0, 0], &[(idx(1, 1, 1), -10000.0)]);
    let look = Vec3::new(150.0, 150.0, 150.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_overlay(world, &field);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    assert!(
        c.b > c.r + 0.10 && c.r > c.g + 0.08 && c.b > c.g + 0.25,
        "cold overlay should be purple (blue>red>green); got {c:?}"
    );
}

/// Electric-potential overlay (top bucket) is warm-yellow: red & green well above
/// blue. Verifies `field_color`'s potential ramp (black→yellow) + alpha render.
#[test]
fn electric_potential_overlay_is_warm() {
    let field = electric_field(
        1,
        [0, 0, 0],
        FIELD_MASK_ELECTRIC_POTENTIAL,
        &[(idx(1, 1, 1), 1000.0)],
    );
    let look = Vec3::new(150.0, 150.0, 150.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_overlay_kind(world, &field, FieldOverlayKind::ElectricPotential);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    assert!(
        c.r > c.b + 0.15 && c.g > c.b + 0.15,
        "potential overlay should be warm-yellow (red&green >> blue); got {c:?}"
    );
}

/// Electric-current overlay (top bucket) is warm amber: red & green above blue.
/// Verifies `field_color`'s current ramp renders (catches a wrong/blue/black hue).
#[test]
fn electric_current_overlay_is_warm() {
    let field = electric_field(
        1,
        [0, 0, 0],
        FIELD_MASK_ELECTRIC_CURRENT,
        &[(idx(1, 1, 1), 1000.0)],
    );
    let look = Vec3::new(150.0, 150.0, 150.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_overlay_kind(world, &field, FieldOverlayKind::ElectricCurrent);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    assert!(
        c.r > c.b + 0.12 && c.g > c.b + 0.10,
        "current overlay should be warm amber (red&green > blue); got {c:?}"
    );
}

/// Ionization overlay (top value) is plasma blue/cyan: blue & green well above
/// red. Verifies the new FieldOverlayKind::Ionization ramp renders (the u8
/// ionization field that was decoded but never drawn before).
#[test]
fn ionization_overlay_is_plasma_cyan() {
    let field = ionization_field(1, [0, 0, 0], &[(idx(1, 1, 1), 255)]);
    let look = Vec3::new(150.0, 150.0, 150.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_overlay_kind(world, &field, FieldOverlayKind::Ionization);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    assert!(
        c.b > c.r + 0.10 && c.g > c.r + 0.15,
        "ionization overlay should be plasma cyan (blue & green above red); got {c:?}"
    );
}

/// The AUTHORITATIVE light field (emergent optics, decoded from the server's
/// `LightPropagationKernel`) renders as a warm-white overlay — blue is the lowest
/// channel (warm), and red/green lift well above the dark-green clear. Verifies the
/// new FieldOverlayKind::Light ramp reaches the screen (light is rendered correctly).
#[test]
fn light_overlay_is_warm_white() {
    let field = light_field(1, [0, 0, 0], &[(idx(1, 1, 1), 255)]);
    let look = Vec3::new(150.0, 150.0, 150.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_overlay_kind(world, &field, FieldOverlayKind::Light);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    let clear = clear_color().to_srgba();
    // Warm-white: red & green lifted above the clear, blue the LOWEST channel
    // (distinguishes warm light from cyan ionization and pure-red hot temperature).
    assert!(
        c.r > clear.red + 0.2 && c.g > clear.green + 0.05,
        "light overlay should lift red & green above the clear; got {c:?}"
    );
    assert!(
        c.b < c.r && c.b < c.g,
        "light overlay should be warm (blue the lowest channel); got {c:?}"
    );
}

/// The AUTHORITATIVE COLORED light field renders each cell in its source's actual
/// color (warm ember vs cool glowstone) — verifies the colored-light path
/// (FIELD_MASK_LIGHT_COLOR, packed-RGB-marker bake + field_color unpack) reaches the
/// screen with the correct hue, on the real GPU.
#[test]
fn colored_light_overlay_renders_source_hue() {
    let look = Vec3::new(150.0, 150.0, 150.0);
    let eye = Vec3::new(150.0, 150.0, -500.0);

    // Warm ember light (0xFFA040) at the aimed cell → warm pixels (red above blue).
    let warm = colored_light_field(1, [0, 0, 0], &[(idx(1, 1, 1), 255, 0xFFA040)]);
    let warm_px = render_scene(|world, image| {
        spawn_camera(world, image, eye, look);
        spawn_overlay_kind(world, &warm, FieldOverlayKind::Light);
    });
    let wc = sample_patch(&warm_px, W / 2, H / 2, 3);
    assert!(
        wc.r > wc.b + 0.10,
        "warm light should render red above blue; got {wc:?}"
    );

    // Cool glowstone light (0x60A0FF) → cool pixels (blue above red).
    let cool = colored_light_field(2, [0, 0, 0], &[(idx(1, 1, 1), 255, 0x60A0FF)]);
    let cool_px = render_scene(|world, image| {
        spawn_camera(world, image, eye, look);
        spawn_overlay_kind(world, &cool, FieldOverlayKind::Light);
    });
    let cc = sample_patch(&cool_px, W / 2, H / 2, 3);
    assert!(
        cc.b > cc.r + 0.10,
        "cool light should render blue above red; got {cc:?}"
    );
}

/// A fully-solid REFINED cell rasterizes to neutral gray via the micro-mesh path
/// — verifies refined_micro_mesh geometry + winding (a winding/normal bug would
/// cull the shell to nothing/black) and per-slot material, never CPU-pixel-tested.
#[test]
fn refined_micro_cell_rasterizes_to_neutral_gray() {
    let chunk = refined_stone_chunk((1, 1, 0));
    let look = Vec3::new(150.0, 150.0, 50.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_chunk_render(world, &chunk);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    let clear = clear_color().to_srgba();
    let off_clear = (c.r - clear.red).abs() + (c.g - clear.green).abs() + (c.b - clear.blue).abs();
    assert!(
        off_clear > 0.15,
        "refined micro shell should rasterize, not clear; got {c:?}"
    );
    let spread = (c.r - c.g)
        .abs()
        .max((c.r - c.b).abs())
        .max((c.g - c.b).abs());
    assert!(
        spread < 0.10,
        "refined stone should be neutral gray; got {c:?}"
    );
    assert!(
        c.r > 0.08,
        "lit refined stone should be non-black; got {c:?}"
    );
}

/// A torch surface decal (type 4, always-visible) on the camera-facing z_neg face
/// renders WARM (red > blue) — verifies the SurfaceDecal render path
/// (surface_decal_mesh + build_decal_mesh + decal_color), never CPU-pixel-tested.
#[test]
fn torch_surface_decal_renders_warm() {
    // Host solid cell (1,1,0); torch decal on its z_neg face (ordinal 4) facing
    // the -Z camera. decal_color(torch=4) = [1.0,0.75,0.20] → red-dominant warm.
    let chunk = decal_chunk((1, 1, 0), 4, 4);
    let look = Vec3::new(150.0, 150.0, 50.0);
    let data = render_scene(|world, image| {
        spawn_camera(world, image, Vec3::new(150.0, 150.0, -500.0), look);
        spawn_decal(world, &chunk);
    });

    let c = sample_patch(&data, W / 2, H / 2, 3);
    let clear = clear_color().to_srgba();
    let off_clear = (c.r - clear.red).abs() + (c.g - clear.green).abs() + (c.b - clear.blue).abs();
    assert!(
        off_clear > 0.15,
        "decal should rasterize, not clear; got {c:?}"
    );
    // Warm hue family (blue is the lowest channel): distinguishes torch/rust
    // (warm) from frost (blue), gray terrain, and the clear color. We assert
    // "blue lowest" rather than R>G because the lit material's strong ambient can
    // clip both R and G to 1.0 for a bright warm color, collapsing their margin.
    assert!(
        c.r > c.b + 0.12 && c.g > c.b + 0.10,
        "torch decal should be warm (red & green above blue); got {c:?}"
    );
}

/// End-to-end: a powered electric field snapshot, run through the REAL
/// `HeatSmokePlugin`, makes heat-smoke particles RASTERIZE on screen — proving
/// the emergence smoke layer is actually visible (not just spawned in the sim).
#[test]
fn heat_smoke_particles_rasterize_on_screen() {
    // High current at local (1,1,1) → ~96 smoke particles near world origin
    // (150, 192, 150) (y=0.92*100). Aim the camera there; smoke is gray over the
    // dark-green clear.
    let field = electric_field(
        1,
        [0, 0, 0],
        FIELD_MASK_ELECTRIC_CURRENT,
        &[(idx(1, 1, 1), 1000.0)],
    );
    let smoke_origin = Vec3::new(150.0, 192.0, 150.0);
    let data = render_with_heat_smoke(&field, Vec3::new(150.0, 192.0, -500.0), smoke_origin);

    // Scan the whole frame for smoke pixels (those differing from the clear
    // color). Smoke rises + jitters, so it lands slightly off the exact aim
    // point — assert on the COUNT + the cluster centroid, not a fixed pixel.
    let clear = clear_color().to_srgba();
    let mut non_clear = 0u32;
    let (mut sx, mut sy) = (0u64, 0u64);
    for y in 0..H {
        for x in 0..W {
            let i = ((y * W + x) * 4) as usize;
            let r = data[i] as f32 / 255.0;
            let g = data[i + 1] as f32 / 255.0;
            let b = data[i + 2] as f32 / 255.0;
            let d = (r - clear.red).abs() + (g - clear.green).abs() + (b - clear.blue).abs();
            if d > 0.06 {
                non_clear += 1;
                sx += x as u64;
                sy += y as u64;
            }
        }
    }
    // The ~50 smoke cubes must rasterize a substantial cluster (emergence visible).
    assert!(
        non_clear > 100,
        "heat-smoke particles should rasterize a visible cluster; got {non_clear} non-clear px"
    );

    // At the smoke cluster centroid, the translucent gray smoke lifts the
    // near-zero red channel of the dark-green clear — confirming it's the gray
    // smoke (not stray geometry).
    let (cx, cy) = (
        (sx / non_clear as u64) as u32,
        (sy / non_clear as u64) as u32,
    );
    let c = sample_patch(&data, cx, cy, 4);
    assert!(
        c.r > clear.red + 0.06,
        "gray smoke should lift the red channel above the clear's; got {c:?}"
    );
}

/// End-to-end: a discharge field snapshot (ionized channel + potential gradient),
/// run through the REAL `LightningPlugin`, makes a lightning bolt RASTERIZE on
/// screen as a bright cyan arc — proving the breakdown/discharge visual is actually
/// visible (the sim's segments reach the GPU, not just the bolt pool).
#[test]
fn lightning_bolt_rasterizes_on_screen() {
    // Ionized channel from cell (1,1,1) [high V, source] to (3,1,1) [low V,
    // target]: world (150,150,150) → (350,150,150), a horizontal arc at y=z=150.
    let field = discharge_field(
        1,
        [0, 0, 0],
        &[
            (idx(1, 1, 1), 200.0, 200),
            (idx(2, 1, 1), 40.0, 190),
            (idx(3, 1, 1), -60.0, 180),
        ],
    );
    let mid = Vec3::new(250.0, 150.0, 150.0);
    let data = render_with_lightning(&field, |w, i| {
        spawn_camera(w, i, Vec3::new(250.0, 150.0, -500.0), mid)
    });

    // Scan the whole frame for bolt pixels (differing from the dark-green clear).
    // The jagged bolt jitters off the straight line, so assert on the COUNT +
    // cluster centroid, not a fixed pixel.
    let clear = clear_color().to_srgba();
    let mut non_clear = 0u32;
    let (mut sx, mut sy) = (0u64, 0u64);
    for y in 0..H {
        for x in 0..W {
            let i = ((y * W + x) * 4) as usize;
            let r = data[i] as f32 / 255.0;
            let g = data[i + 1] as f32 / 255.0;
            let b = data[i + 2] as f32 / 255.0;
            let d = (r - clear.red).abs() + (g - clear.green).abs() + (b - clear.blue).abs();
            if d > 0.06 {
                non_clear += 1;
                sx += x as u64;
                sy += y as u64;
            }
        }
    }
    assert!(
        non_clear > 80,
        "lightning bolt should rasterize a visible arc; got {non_clear} non-clear px"
    );

    // At the bolt centroid (where the overlapping segments are solidly covered),
    // the cyan bolt's blue channel dominates: blue is high and well above red — the
    // cyan signature distinguishing it from gray geometry or the warm clear color.
    let (cx, cy) = (
        (sx / non_clear as u64) as u32,
        (sy / non_clear as u64) as u32,
    );
    let c = sample_patch(&data, cx, cy, 4);
    assert!(
        c.b > 0.45 && c.b > c.r + 0.10,
        "bolt should be cyan (blue high, blue above red); got {c:?}"
    );
    assert!(
        c.b > clear.blue + 0.20,
        "bolt blue should lift well above the clear's blue; got {c:?}"
    );
}

/// End-to-end (emergent optics): a HOT temperature field, run through the REAL
/// `IncandescencePlugin`, rasterizes an additive blackbody glow whose color is
/// DERIVED from temperature — a warm cell glows red-orange, and a HOTTER cell
/// glows whiter/brighter (green + blue channels climb). Proves the glow emerges
/// from the temperature field, not from any per-material authoring.
#[test]
fn incandescence_glow_color_emerges_from_temperature() {
    // One glowing cell at local (1,1,1): world center ~ (150,150,150). Aim there.
    let eye = Vec3::new(150.0, 150.0, -500.0);
    let look = Vec3::new(150.0, 150.0, 150.0);

    // Warm: 900°C → red-orange glow (red dominates, blue near the clear baseline).
    let warm = render_with_incandescence(
        &incandescence_temp_field(1, [0, 0, 0], &[(idx(1, 1, 1), 900.0)]),
        |w, i| spawn_camera(w, i, eye, look),
    );
    let warm_c = glow_centroid(&warm);
    let clear = clear_color().to_srgba();
    assert!(
        warm_c.r > 0.5 && warm_c.r > warm_c.b + 0.3,
        "900C cell should glow warm red-orange (red dominant, low blue); got {warm_c:?}"
    );
    assert!(
        warm_c.r > clear.red + 0.2,
        "glow should additively lift red above the clear; got {warm_c:?}"
    );

    // Hotter: 1800°C → shifts toward white — green AND blue rise vs the 900°C glow.
    let hot = render_with_incandescence(
        &incandescence_temp_field(2, [0, 0, 0], &[(idx(1, 1, 1), 1800.0)]),
        |w, i| spawn_camera(w, i, eye, look),
    );
    let hot_c = glow_centroid(&hot);
    assert!(
        hot_c.g > warm_c.g + 0.10 && hot_c.b > warm_c.b + 0.10,
        "1800C glow must be whiter than 900C (green & blue climb with temperature); \
         warm={warm_c:?} hot={hot_c:?}"
    );
}

// ============================================================================
// Showcase: real-GPU off-screen renders of the key client features, saved as PNG.
// The user cannot run the GUI, so these ARE the visual proof — real meshes, real
// materials, real emergence effects. Output: clients/bevy_client/showcase_out/*.png
//
// Run: cargo test --features layer3 --lib voxel::layer3_pixel::showcase \
//        -- --test-threads=1 --nocapture
// Single-threaded is mandatory (each render owns a Vulkan device; module header).
// ============================================================================

fn showcase_out_dir() -> std::path::PathBuf {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("showcase_out");
    std::fs::create_dir_all(&dir).expect("create showcase_out dir");
    dir
}

fn save_showcase_png(name: &str, data: &[u8]) {
    let path = showcase_out_dir().join(format!("{name}.png"));
    let file = std::fs::File::create(&path).expect("create png");
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), W, H);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header()
        .expect("png header")
        .write_image_data(data)
        .expect("png data");
    eprintln!("showcase: wrote {} ({W}x{H})", path.display());
}

fn showcase_material_chunk(cells: &[(i32, i32, i32, u16)]) -> AuthorityChunk {
    let size = 16usize;
    let mut grid = vec![CellState::Empty; size * size * size];
    for &(x, y, z, m) in cells {
        let i = (x + y * size as i32 + z * size as i32 * size as i32) as usize;
        grid[i] = stone(m);
    }
    AuthorityChunk {
        chunk_version: 1,
        chunk_size_in_macro: size as u8,
        cells: grid,
        ..Default::default()
    }
}

/// Daylight horizon color (low sky / haze) and zenith color (high sky), for the
/// gradient skydome + sky-fill ambient. Bright values (vertex colors render in
/// linear space, unlit) so the dome reads as a clear daytime sky, not dusk.
fn sky_horizon() -> Color {
    Color::srgb(0.92, 0.95, 0.99)
}
fn sky_zenith() -> Color {
    Color::srgb(0.40, 0.62, 0.95)
}

/// Environment camera for showcase scenes: a gradient sky-blue clear + a warm
/// sun + a cool sky-fill ambient, tonemap off so colors stay predictable. Gives a
/// real-feeling outdoor scene without the off-screen atmosphere pipeline (which
/// washes out when rendered to a texture target rather than the main window).
fn spawn_sky_camera(world: &mut World, image: Handle<Image>, eye: Vec3, look: Vec3) {
    world.spawn((
        Camera3d::default(),
        Camera {
            clear_color: ClearColorConfig::Custom(sky_horizon()),
            ..default()
        },
        RenderTarget::Image(image.into()),
        Tonemapping::None,
        // Cool sky-tinted fill so shadowed faces read as "sky-lit", not black.
        AmbientLight {
            color: Color::srgb(0.55, 0.66, 0.85),
            brightness: 700.0,
            ..default()
        },
        Transform::from_translation(eye).looking_at(look, Vec3::Y),
    ));
    // Warm sun from upper-left; gives the blocks directional shading (form).
    world.spawn((
        DirectionalLight {
            color: Color::srgb(1.0, 0.96, 0.86),
            illuminance: 4200.0,
            shadows_enabled: false,
            ..default()
        },
        Transform::from_xyz(-0.6, 1.0, 0.45).looking_at(Vec3::ZERO, Vec3::Y),
    ));
}

/// Night/twilight camera for the additive glow effects (incandescence, lightning):
/// a dark blue-black clear so the bright emissive glow + bolt pop (they would wash
/// out on a bright day sky). Low cool ambient keeps any geometry faintly visible.
fn spawn_night_camera(world: &mut World, image: Handle<Image>, eye: Vec3, look: Vec3) {
    world.spawn((
        Camera3d::default(),
        Camera {
            clear_color: ClearColorConfig::Custom(Color::srgb(0.03, 0.04, 0.09)),
            ..default()
        },
        RenderTarget::Image(image.into()),
        Tonemapping::None,
        AmbientLight {
            color: Color::srgb(0.35, 0.45, 0.75),
            brightness: 150.0,
            ..default()
        },
        Transform::from_translation(eye).looking_at(look, Vec3::Y),
    ));
}

/// A large inverted sphere with a vertical sky gradient (horizon → zenith), unlit
/// and double-sided so the camera inside sees a gradient sky behind the terrain.
fn spawn_skydome(world: &mut World, center: Vec3) {
    let radius = 7000.0;
    let mut mesh = Sphere::new(radius).mesh().uv(48, 32);
    let positions = match mesh.attribute(Mesh::ATTRIBUTE_POSITION) {
        Some(bevy::mesh::VertexAttributeValues::Float32x3(p)) => p.clone(),
        _ => vec![],
    };
    let lo = sky_horizon().to_srgba();
    let hi = sky_zenith().to_srgba();
    let colors: Vec<[f32; 4]> = positions
        .iter()
        .map(|p| {
            // t: 0 at horizon (y=0), 1 at zenith (y=+r); bias the gradient up.
            let t = ((p[1] / radius).clamp(0.0, 1.0)).powf(0.6);
            [
                lo.red + (hi.red - lo.red) * t,
                lo.green + (hi.green - lo.green) * t,
                lo.blue + (hi.blue - lo.blue) * t,
                1.0,
            ]
        })
        .collect();
    if !colors.is_empty() {
        mesh.insert_attribute(Mesh::ATTRIBUTE_COLOR, colors);
    }
    let mesh_h = world.resource_mut::<Assets<Mesh>>().add(mesh);
    let mat = world
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::WHITE,
            unlit: true,
            cull_mode: None,
            ..default()
        });
    world.spawn((
        Mesh3d(mesh_h),
        MeshMaterial3d(mat),
        Transform::from_translation(center),
    ));
}

/// Real mesh path with per-material vertex colors AND the procedural mosaic block
/// texture — the terrain exactly as the live client draws it (textured, not flat).
fn spawn_chunk_textured(world: &mut World, chunk: &AuthorityChunk) {
    let data = chunk_render_mesh(chunk, MACRO, &ChunkNeighbors::default());
    let mesh = build_mesh_with_colors(&data, material_color);
    let mesh_handle = world.resource_mut::<Assets<Mesh>>().add(mesh);
    let texture = world
        .resource_mut::<Assets<Image>>()
        .add(mosaic_block_texture());
    let material = world
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::WHITE,
            base_color_texture: Some(texture),
            perceptual_roughness: 0.9,
            ..default()
        });
    world.spawn((
        Mesh3d(mesh_handle),
        MeshMaterial3d(material),
        Transform::from_translation(Vec3::ZERO),
    ));
}

/// A small textured voxel landscape: a grassy heightmap floor (grass on top,
/// dirt then stone below) with a tree (wood trunk + leaves), a glowstone lamp, a
/// lava patch and a water pool — material variety under the real client material
/// palette, drawn with the mosaic texture.
fn showcase_landscape_chunk() -> AuthorityChunk {
    let mut cells: Vec<(i32, i32, i32, u16)> = vec![];
    let size = 9i32;
    for x in 0..size {
        for z in 0..size {
            // Gentle blocky height variation (0..2 above the base).
            let h = 1 + (((x * 7 + z * 13 + x * z) % 3).unsigned_abs() as i32);
            for y in 0..h {
                // grass(sprout 18) on top, dirt(1) just below, stone(2) deeper.
                let mat = if y == h - 1 {
                    18
                } else if y + 1 >= h - 1 {
                    1
                } else {
                    2
                };
                cells.push((x, y, z, mat));
            }
        }
    }
    // A tree: wood(3) trunk + sprout(18) leaf canopy.
    let (tx, tz) = (2i32, 6i32);
    for y in 2..5 {
        cells.push((tx, y, tz, 3));
    }
    for dx in -1..=1 {
        for dz in -1..=1 {
            cells.push((tx + dx, 5, tz + dz, 18));
        }
    }
    cells.push((tx, 6, tz, 18));
    // A glowstone lamp post, a lava patch, and a small water pool.
    cells.push((6, 3, 2, 3));
    cells.push((6, 4, 2, 19)); // glowstone lamp on a post
    cells.push((7, 1, 6, 15)); // lava
    cells.push((1, 1, 1, 8)); // water
    cells.push((1, 1, 2, 8));
    cells.push((2, 1, 1, 8));
    showcase_material_chunk(&cells)
}

/// A flat textured grass floor (`w`×`d` cells at y=0) to stage emergence effects
/// in the world environment instead of on a flat background.
fn floor_chunk(w: i32, d: i32) -> AuthorityChunk {
    let mut cells = vec![];
    for x in 0..w {
        for z in 0..d {
            cells.push((x, 0, z, 18)); // grass
        }
    }
    showcase_material_chunk(&cells)
}

/// 1. Voxel world — a textured voxel landscape under the real procedural sky +
///    sunlight (the live client's environment), proving the base rendering: the
///    greedy mesh, the per-material palette, the mosaic block texture, real
///    atmosphere/lighting.
#[test]
fn showcase_voxel_world() {
    let chunk = showcase_landscape_chunk();
    let eye = Vec3::new(1180.0, 760.0, -240.0);
    let look = Vec3::new(430.0, 90.0, 430.0);
    let data = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured(world, &chunk);
    });
    save_showcase_png("01_voxel_world", &data);
    assert_eq!(data.len(), (W * H * 4) as usize);
}

/// 2. Emergent colored light — the authoritative `:light` + `:light_color` field:
///    warm ember sources (0xFFA040) and cool glowstone sources (0x60A0FF). The hue
///    emerges from the server light field, not per-material authoring.
#[test]
fn showcase_emergent_colored_light() {
    let light = colored_light_field(
        1,
        [0, 0, 0],
        &[
            (idx(1, 1, 1), 255, 0xFF_A040),
            (idx(3, 1, 1), 255, 0x60_A0FF),
            (idx(2, 2, 1), 210, 0xFF_A040),
            (idx(2, 1, 2), 220, 0x60_A0FF),
        ],
    );
    let eye = Vec3::new(230.0, 250.0, -360.0);
    let look = Vec3::new(230.0, 150.0, 170.0);
    let data = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured(world, &floor_chunk(5, 5));
        spawn_overlay_kind(world, &light, FieldOverlayKind::Light);
    });
    save_showcase_png("02_emergent_colored_light", &data);
    assert_eq!(data.len(), (W * H * 4) as usize);
}

/// 3. Thermal incandescence — a row of cells at rising temperature glows with color
///    DERIVED from temperature: ~700C red, ~1200C orange, ~1800C white-hot.
#[test]
fn showcase_thermal_incandescence() {
    let field = incandescence_temp_field(
        1,
        [0, 0, 0],
        &[
            (idx(1, 1, 1), 700.0),
            (idx(2, 1, 1), 1200.0),
            (idx(3, 1, 1), 1800.0),
        ],
    );
    let data = render_with_incandescence(&field, |w, i| {
        spawn_night_camera(
            w,
            i,
            Vec3::new(250.0, 150.0, -440.0),
            Vec3::new(250.0, 150.0, 150.0),
        )
    });
    save_showcase_png("03_thermal_incandescence", &data);
    assert_eq!(data.len(), (W * H * 4) as usize);
}

/// 4. Electric discharge — a breakdown channel arcs a jagged cyan lightning bolt.
#[test]
fn showcase_lightning_arc() {
    let field = discharge_field(
        1,
        [0, 0, 0],
        &[
            (idx(1, 1, 1), 200.0, 200),
            (idx(2, 1, 1), 40.0, 190),
            (idx(3, 1, 1), -60.0, 180),
        ],
    );
    let data = render_with_lightning(&field, |w, i| {
        spawn_night_camera(
            w,
            i,
            Vec3::new(250.0, 150.0, -440.0),
            Vec3::new(250.0, 150.0, 150.0),
        )
    });
    save_showcase_png("04_lightning_arc", &data);
    assert_eq!(data.len(), (W * H * 4) as usize);
}

/// 5. Temperature field truth — hot cells (red) + cold cells (purple) on the
///    thermal overlay ramp: the committed temperature field made visible.
#[test]
fn showcase_temperature_field() {
    let field = temperature_field(
        1,
        [0, 0, 0],
        &[
            (idx(1, 2, 1), 10000.0),
            (idx(2, 3, 1), 8000.0),
            (idx(3, 2, 2), -250.0),
            (idx(2, 2, 3), -180.0),
        ],
    );
    let eye = Vec3::new(230.0, 300.0, -360.0);
    let look = Vec3::new(230.0, 180.0, 170.0);
    let data = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured(world, &floor_chunk(5, 5));
        spawn_overlay(world, &field);
    });
    save_showcase_png("05_temperature_field_hot_cold", &data);
    assert_eq!(data.len(), (W * H * 4) as usize);
}

/// 6. Ionization plasma — the breakdown-conditioning field on the dark-blue to cyan
///    plasma ramp (the conditioned discharge channel made visible).
#[test]
fn showcase_ionization_plasma() {
    let field = discharge_field(
        1,
        [0, 0, 0],
        &[
            (idx(1, 2, 1), 0.0, 240),
            (idx(2, 2, 1), 0.0, 220),
            (idx(3, 2, 1), 0.0, 200),
            (idx(2, 2, 2), 0.0, 180),
        ],
    );
    let eye = Vec3::new(230.0, 300.0, -360.0);
    let look = Vec3::new(230.0, 180.0, 170.0);
    let data = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured(world, &floor_chunk(5, 5));
        spawn_overlay_kind(world, &field, FieldOverlayKind::Ionization);
    });
    save_showcase_png("06_ionization_plasma", &data);
    assert_eq!(data.len(), (W * H * 4) as usize);
}

// ---- Structural collapse → debris (力学应力 step6) ---------------------------

/// Drives the REAL [`DebrisSimulation`] (parity physics): a burst at each collapse
/// point (macro-cell coords), integrated `dt_ms` so the cloud lifts/spreads/falls,
/// then a brown cube per live particle at the scaled world position — size + color
/// matching `debris_render` (0.05 m × macro = 5 render units). The rng is a fixed
/// xorshift so the cloud is reproducible (Date/random are unavailable here anyway).
/// Returns the live particle count actually spawned.
fn spawn_collapse_debris(world: &mut World, points: &[(f32, f32, f32)], dt_ms: f32) -> usize {
    let mut sim = DebrisSimulation::with_config(DebrisConfig {
        burst_size: 18,
        ..Default::default()
    });
    let spawn_points: Vec<DebrisSpawnPoint> = points
        .iter()
        .map(|&(x, y, z)| DebrisSpawnPoint { x, y, z })
        .collect();

    let mut state = 0x9E37_79B9_7F4A_7C15u64;
    let mut rng = || {
        let mut x = state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        state = x;
        ((x >> 40) as f32) / ((1u64 << 24) as f32)
    };
    sim.spawn(&spawn_points, DebrisKind::Destroyed, &mut rng);
    sim.update(dt_ms);

    let edge = DEFAULT_PARTICLE_SIZE_M * MACRO;
    let mesh = world
        .resource_mut::<Assets<Mesh>>()
        .add(Cuboid::from_length(edge));
    let mat = world
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::srgb(0.55, 0.27, 0.075), // debris brown
            perceptual_roughness: 0.85,
            ..default()
        });

    let live = sim.live_particles();
    for p in live {
        let pos = Vec3::new(p.x, p.y, p.z) * MACRO;
        world.spawn((
            Mesh3d(mesh.clone()),
            MeshMaterial3d(mat.clone()),
            Transform::from_translation(pos),
        ));
    }
    live.len()
}

/// A collapse scene: a grass floor + the surviving supported stub of a stone column
/// (local y=1,2), its now-unsupported top GONE (collapsed) — the falling rubble is
/// the debris cloud above the stub.
fn collapse_scene_chunk() -> AuthorityChunk {
    let mut cells: Vec<(i32, i32, i32, u16)> = vec![];
    for x in 1..8 {
        for z in 1..8 {
            cells.push((x, 0, z, 18)); // grass floor
        }
    }
    // Surviving stone stub (still connected to the ground) — the top two cells
    // (3,3,3),(3,4,3) collapsed and are now debris mid-air.
    cells.push((3, 1, 3, 2));
    cells.push((3, 2, 3, 2));
    showcase_material_chunk(&cells)
}

/// 7. Structural collapse → debris — the 5th orthogonal physics system (mechanical
///    stress) on screen: an unsupported column top has collapsed into a brown debris
///    cloud (real `DebrisSimulation` spread/fall) raining over its surviving base,
///    under the live sky. Visual evidence the server's `:collapse_block` truth lands
///    as falling rubble on the client.
#[test]
fn showcase_structural_collapse_debris() {
    let chunk = collapse_scene_chunk();
    // Collapsed top of the column was around macro (3, 3..4, 3) → world ~3.5×100.
    let debris_points = [
        (3.5, 3.4, 3.5),
        (3.2, 3.8, 3.6),
        (3.8, 3.6, 3.3),
        (3.4, 4.2, 3.4),
        (3.6, 3.2, 3.7),
    ];
    let eye = Vec3::new(470.0, 360.0, -40.0);
    let look = Vec3::new(330.0, 250.0, 330.0);
    let data = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured(world, &chunk);
        spawn_collapse_debris(world, &debris_points, 220.0);
    });
    save_showcase_png("07_structural_collapse_debris", &data);
    assert_eq!(data.len(), (W * H * 4) as usize);
}

/// End-to-end pixel proof: a collapse debris burst actually RASTERIZES brown cubes
/// on screen (isolated against the dark clear so the non-clear pixels ARE the
/// debris). Mirrors the lightning/heat-smoke rasterize assertions.
#[test]
fn collapse_debris_rasterizes_on_screen() {
    let debris_points = [
        (2.0, 2.0, 2.0),
        (2.3, 2.4, 2.1),
        (1.8, 2.2, 2.3),
        (2.2, 1.8, 1.9),
    ];
    let data = render_scene(|world, image| {
        spawn_camera(
            world,
            image,
            Vec3::new(200.0, 230.0, -120.0),
            Vec3::new(205.0, 205.0, 205.0),
        );
        let n = spawn_collapse_debris(world, &debris_points, 180.0);
        assert!(n >= 50, "expected a dense debris cloud, spawned {n}");
    });

    // Count non-clear pixels and their centroid color — they must be the debris cubes.
    let clear = clear_color().to_srgba();
    let mut non_clear = 0u32;
    let (mut sx, mut sy) = (0u64, 0u64);
    for y in 0..H {
        for x in 0..W {
            let i = ((y * W + x) * 4) as usize;
            let r = data[i] as f32 / 255.0;
            let g = data[i + 1] as f32 / 255.0;
            let b = data[i + 2] as f32 / 255.0;
            let d = (r - clear.red).abs() + (g - clear.green).abs() + (b - clear.blue).abs();
            if d > 0.06 {
                non_clear += 1;
                sx += x as u64;
                sy += y as u64;
            }
        }
    }

    assert!(
        non_clear > 60,
        "collapse debris should rasterize a visible cloud; got {non_clear} non-clear px"
    );

    let (cx, cy) = ((sx / non_clear as u64) as u32, (sy / non_clear as u64) as u32);
    let px = sample_patch(&data, cx, cy, 6);
    // Debris is brown: warm (red ≥ blue), not the green clear and not gray sky.
    assert!(
        px.r >= px.b,
        "debris cloud should read warm/brown (r {:.2} ≥ b {:.2})",
        px.r,
        px.b
    );
}

// ---- 光可见度 Phase A · 弥漫光场(天光 lightmap)----------------------------

/// Core lit-mesh spawn: meshes `chunk` with an arbitrary per-cell light closure and
/// the live textured material. The skylight-only and block-light showcases share it.
fn spawn_chunk_lit_with(
    world: &mut World,
    chunk: &AuthorityChunk,
    light_at: &dyn Fn(i32, i32, i32) -> f32,
) {
    let data = chunk_render_mesh_lit(chunk, MACRO, &ChunkNeighbors::default(), Some(light_at));
    let mesh = build_mesh_with_colors(&data, material_color);
    let mesh_handle = world.resource_mut::<Assets<Mesh>>().add(mesh);
    let texture = world
        .resource_mut::<Assets<Image>>()
        .add(mosaic_block_texture());
    let material = world
        .resource_mut::<Assets<StandardMaterial>>()
        .add(StandardMaterial {
            base_color: Color::WHITE,
            base_color_texture: Some(texture),
            perceptual_roughness: 0.9,
            ..default()
        });
    world.spawn((
        Mesh3d(mesh_handle),
        MeshMaterial3d(material),
        Transform::from_translation(Vec3::ZERO),
    ));
}

/// Skylight-only closure for a chunk (top boundary = open sky, sides clamp in).
fn skylight_light_at(chunk: &AuthorityChunk) -> (Skylight, i32) {
    (
        Skylight::compute(chunk, SkylightConfig::default()),
        chunk.chunk_size_in_macro as i32,
    )
}

/// Like `spawn_chunk_textured` but bakes the skylight lightmap into the mesh (the
/// live client's lit path): covered/underground cells render dark, open cells full.
fn spawn_chunk_textured_lit(world: &mut World, chunk: &AuthorityChunk) {
    let (sky, size) = skylight_light_at(chunk);
    let light_at = |x: i32, y: i32, z: i32| -> f32 {
        if y >= size {
            1.0
        } else {
            sky.at(x.clamp(0, size - 1), y.clamp(0, size - 1), z.clamp(0, size - 1))
        }
    };
    spawn_chunk_lit_with(world, chunk, &light_at);
}

/// The live block-light path: combined light = max(skylight, block light). `block`
/// is a list of (chunk-local cell, u8 intensity) mirroring a `:light` field flood
/// from a source (e.g. a torch in a cave). Sampled like the real grid (macro_index
/// == cell flat index x + y*16 + z*256).
fn spawn_chunk_textured_lit_blocklight(
    world: &mut World,
    chunk: &AuthorityChunk,
    block: &[((i32, i32, i32), u8)],
) {
    let (sky, size) = skylight_light_at(chunk);
    let mut grid = vec![0u8; 16 * 16 * 16];
    for &((x, y, z), level) in block {
        if (0..16).contains(&x) && (0..16).contains(&y) && (0..16).contains(&z) {
            grid[(x + y * 16 + z * 256) as usize] = level;
        }
    }
    let light_at = |x: i32, y: i32, z: i32| -> f32 {
        let sky_l = if y >= size {
            1.0
        } else {
            sky.at(x.clamp(0, size - 1), y.clamp(0, size - 1), z.clamp(0, size - 1))
        };
        let block_l = if (0..16).contains(&x) && (0..16).contains(&y) && (0..16).contains(&z) {
            grid[(x + y * 16 + z * 256) as usize] as f32 / 255.0
        } else {
            0.0
        };
        sky_l.max(block_l)
    };
    spawn_chunk_lit_with(world, chunk, &light_at);
}

/// A torch-style block-light flood (center bright, falling off) seated in the shaded
/// alcove of `overhang_chunk` (air cells just above the covered floor).
fn alcove_torch_block_light() -> Vec<((i32, i32, i32), u8)> {
    vec![
        ((2, 1, 3), 255),
        ((2, 1, 2), 200),
        ((2, 1, 4), 200),
        ((1, 1, 3), 200),
        ((3, 1, 3), 190),
        ((2, 2, 3), 170),
        ((2, 1, 1), 130),
        ((2, 1, 5), 130),
        ((1, 1, 2), 150),
        ((3, 1, 4), 150),
    ]
}

/// A grass floor with an L-shaped stone overhang (back wall + roof) covering the
/// left half — the covered floor cells lose skylight (dark alcove) while the right
/// half stays open (full daylight). The canonical "surface bright, shelter/cave dark".
fn overhang_chunk() -> AuthorityChunk {
    let mut cells: Vec<(i32, i32, i32, u16)> = vec![];
    let span = 9i32;
    for x in 0..span {
        for z in 0..span {
            cells.push((x, 0, z, 18)); // grass floor
        }
    }
    // Back wall (x=0) and a roof slab (y=5) over the left half → shaded alcove.
    for z in 0..span {
        for y in 1..6 {
            cells.push((0, y, z, 2)); // stone back wall
        }
        for x in 0..5 {
            cells.push((x, 5, z, 2)); // stone roof
        }
    }
    showcase_material_chunk(&cells)
}

/// Mean luma over the whole framebuffer (sky identical between two renders of the
/// same scene → the difference isolates terrain shading).
fn mean_luma(data: &[u8]) -> f32 {
    let mut sum = 0.0;
    let n = (W * H) as f32;
    for px in data.chunks_exact(4) {
        sum += 0.299 * px[0] as f32 + 0.587 * px[1] as f32 + 0.114 * px[2] as f32;
    }
    sum / (n * 255.0)
}

/// 8. Diffuse skylight — the world has light and dark: a sunlit grass terrace with
///    a shaded stone alcove under an overhang, brightness driven per-cell by the
///    baked skylight lightmap (replacing the fixed uniform ambient).
#[test]
fn showcase_skylight_diffuse() {
    let chunk = overhang_chunk();
    let eye = Vec3::new(1180.0, 720.0, -220.0);
    let look = Vec3::new(430.0, 120.0, 430.0);
    let data = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured_lit(world, &chunk);
    });
    save_showcase_png("08_skylight_diffuse", &data);
    assert_eq!(data.len(), (W * H * 4) as usize);
}

/// End-to-end pixel proof: baking the skylight lightmap darkens the covered terrain
/// — the lit render of an overhang scene is measurably darker than the same scene
/// drawn with the flat (uniform-bright) material path. Isolates the lightmap effect
/// (same geometry, same sky, same camera; only the per-cell light differs).
#[test]
fn skylight_darkens_covered_terrain() {
    let chunk = overhang_chunk();
    let eye = Vec3::new(1180.0, 720.0, -220.0);
    let look = Vec3::new(430.0, 120.0, 430.0);

    let lit = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured_lit(world, &chunk);
    });
    let flat = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured(world, &chunk); // uniform albedo (no skylight)
    });

    let mean_lit = mean_luma(&lit);
    let mean_flat = mean_luma(&flat);
    assert!(
        mean_lit < mean_flat * 0.94,
        "skylight should darken the shaded terrain: lit mean {mean_lit:.4} vs flat {mean_flat:.4}"
    );
}

/// 9. Block light fills the dark — a torch (the server `:light` field) seated in the
///    shaded alcove illuminates the surrounding floor/walls, so caves are dark BUT
///    light sources brighten them (combined light = max(skylight, block light)).
#[test]
fn showcase_block_light_torch_in_alcove() {
    let chunk = overhang_chunk();
    let eye = Vec3::new(1180.0, 720.0, -220.0);
    let look = Vec3::new(430.0, 120.0, 430.0);
    let torch = alcove_torch_block_light();
    let data = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured_lit_blocklight(world, &chunk, &torch);
    });
    save_showcase_png("09_block_light_torch", &data);
    assert_eq!(data.len(), (W * H * 4) as usize);
}

/// End-to-end pixel proof: a block-light source brightens the otherwise-dark covered
/// alcove — the scene WITH the torch reads brighter than the same scene WITHOUT it
/// (skylight only). Same geometry/sky/camera; only the block-light field differs.
#[test]
fn block_light_brightens_shaded_alcove() {
    let chunk = overhang_chunk();
    let eye = Vec3::new(1180.0, 720.0, -220.0);
    let look = Vec3::new(430.0, 120.0, 430.0);

    let torched = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured_lit_blocklight(world, &chunk, &alcove_torch_block_light());
    });
    let dark = render_scene(|world, image| {
        spawn_sky_camera(world, image, eye, look);
        spawn_skydome(world, eye);
        spawn_chunk_textured_lit(world, &chunk); // skylight only — no torch
    });

    let mean_torched = mean_luma(&torched);
    let mean_dark = mean_luma(&dark);
    assert!(
        mean_torched > mean_dark * 1.02,
        "a torch should brighten the shaded alcove: torched {mean_torched:.4} vs dark {mean_dark:.4}"
    );
}
