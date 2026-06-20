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

use crate::voxel::authority::{AuthorityChunk, CellState};
use crate::voxel::chunk_render::{build_mesh, build_mesh_with_colors};
use crate::voxel::field_render::{FieldOverlayMaterial, field_overlay_material};
use crate::voxel::field_view::{FieldOverlayKind, field_color, overlay_mesh};
use crate::voxel::mesher::greedy_mesh_chunk;
use crate::voxel::wire::{FIELD_MASK_TEMPERATURE, FieldRegionSnapshot, NormalBlock};

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
    let data = overlay_mesh(field, FieldOverlayKind::Temperature, MACRO);
    assert!(!data.is_empty(), "overlay produced no geometry");
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
