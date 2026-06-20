//! Layer-3 GPU pixel verification (feature `layer3`, GPU required).
//!
//! Renders the REAL voxel meshes + materials off-screen on the local GPU and
//! reads the framebuffer back to assert rendering properties that the CPU
//! mesh/data tests structurally CANNOT — chiefly that the field overlay's
//! depth-disable material (`FieldDepthDisable` extension, the #6 fix) renders
//! THROUGH opaque terrain, which is a GPU pipeline-state property, not mesh data.
//!
//! Gating: behind the `layer3` cargo feature so normal `cargo test` needs no GPU.
//! Run with `cargo test --features layer3 layer3_pixel` (locally with a GPU, or
//! in the lavapipe CI job).
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
use crate::voxel::chunk_render::{build_decal_mesh, build_mesh, build_mesh_with_colors};
use crate::voxel::field_render::{FieldOverlayMaterial, field_overlay_material};
use crate::voxel::field_view::{FieldOverlayKind, field_color, overlay_mesh};
use crate::voxel::mesher::{ChunkNeighbors, chunk_render_mesh, greedy_mesh_chunk};
use crate::voxel::surface_decal::surface_decal_mesh;
use crate::voxel::wire::{
    FIELD_MASK_ELECTRIC_CURRENT, FIELD_MASK_ELECTRIC_POTENTIAL, FIELD_MASK_TEMPERATURE,
    FieldRegionSnapshot, MaskWords, MicroLayer, NormalBlock, RefinedCell, SurfaceElement,
    VoxelServerMessage,
};
use crate::voxel::{HeatSmokePlugin, VoxelAuthority};

/// Framebuffer size. Width divisible by 64 → RGBA8 row bytes (W*4) divisible by
/// 256 → no GPU row padding to de-pad on readback.
const W: u32 = 256;
const H: u32 = 256;
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

    // Pump enough frames that the camera has rendered and a post-render readback
    // has landed (readback has ~1-frame latency).
    for _ in 0..16 {
        app.update();
    }
    let data = app
        .world()
        .resource::<Captured>()
        .0
        .clone()
        .expect("gpu readback never completed (no adapter? render failed?)");
    let nonzero = data.iter().filter(|&&b| b != 0).count();
    eprintln!(
        "[layer3] readback {} bytes, {} non-zero ({:.1}%)",
        data.len(),
        nonzero,
        100.0 * nonzero as f32 / data.len() as f32
    );
    data
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
    let size = 16usize;
    let mut cells = vec![CellState::Empty; size * size * size];
    for &(x, y, z) in solid_cells {
        let idx = (x + y * size as i32 + z * size as i32 * size as i32) as usize;
        cells[idx] = stone(2);
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
    for _ in 0..20 {
        app.update();
    }
    app.world()
        .resource::<Captured>()
        .0
        .clone()
        .expect("gpu readback never completed")
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
