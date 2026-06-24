//! Bottom-centre **build hotbar**: renders the live `BuildPalette` as a row of
//! colour swatches with the selected entry highlighted, plus its name / kind /
//! index above. Closes the "selecting a different block shows nothing" gap — the
//! legacy HUD line only ever reflected the *offline* showcase hotbar
//! (`VoxelWorld::hotbar`), never the server-authoritative construction palette
//! the digit keys / wheel actually drive in a live scene.

use bevy::prelude::*;

use crate::login::AppState;
use crate::voxel::build_palette::{BuildKind, BuildPalette};
use crate::voxel::chunk_render::material_color;

#[derive(Component)]
struct BuildHotbarRoot;

/// One palette slot, tagged with its index into `BuildPalette::entries`.
#[derive(Component)]
struct BuildHotbarSlot(usize);

#[derive(Component)]
struct BuildHotbarLabel;

pub struct BuildHotbarPlugin;

impl Plugin for BuildHotbarPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(OnEnter(AppState::Game), setup_build_hotbar)
            .add_systems(
                Update,
                update_build_hotbar.run_if(in_state(AppState::Game)),
            );
    }
}

/// Swatch colour for a palette entry: materials reuse the chunk renderer's
/// per-vertex palette so the swatch matches the placed block; prefab runs and
/// surface fixtures (which have no single material colour) get fixed accents.
fn slot_color(kind: BuildKind) -> Color {
    match kind {
        BuildKind::Material(id) => {
            let c = material_color(id as u32);
            Color::srgb(c[0], c[1], c[2])
        }
        BuildKind::Prefab(_) => Color::srgb(0.40, 0.52, 0.78),
        BuildKind::Surface(_) => Color::srgb(0.85, 0.66, 0.28),
    }
}

fn setup_build_hotbar(mut commands: Commands, palette: Res<BuildPalette>) {
    // Full-width anchor at the very bottom; the actual hotbar is a centred dark
    // panel inside it so the label/swatches read cleanly over terrain and the
    // bottom-left debug log instead of fighting them for contrast.
    commands
        .spawn((
            BuildHotbarRoot,
            Node {
                position_type: PositionType::Absolute,
                bottom: px(10),
                left: px(0),
                width: Val::Percent(100.0),
                flex_direction: FlexDirection::Column,
                align_items: AlignItems::Center,
                ..default()
            },
        ))
        .with_children(|root| {
            root.spawn((
                Node {
                    flex_direction: FlexDirection::Column,
                    align_items: AlignItems::Center,
                    row_gap: px(6),
                    padding: UiRect::all(px(8)),
                    ..default()
                },
                BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.55)),
            ))
            .with_children(|panel| {
                panel.spawn((
                    BuildHotbarLabel,
                    Text::new(""),
                    TextFont {
                        font_size: FontSize::Px(20.0),
                        ..default()
                    },
                    TextColor(Color::srgb(1.0, 0.95, 0.7)),
                ));

                panel
                    .spawn(Node {
                        flex_direction: FlexDirection::Row,
                        column_gap: px(4),
                        ..default()
                    })
                    .with_children(|row| {
                        for (i, entry) in palette.entries().iter().enumerate() {
                            row.spawn((
                                BuildHotbarSlot(i),
                                Node {
                                    width: px(40),
                                    height: px(26),
                                    border: UiRect::all(px(2)),
                                    ..default()
                                },
                                BackgroundColor(slot_color(entry.kind)),
                                BorderColor::all(Color::srgba(0.0, 0.0, 0.0, 0.6)),
                            ));
                        }
                    });
            });
        });
}

fn update_build_hotbar(
    palette: Res<BuildPalette>,
    mut slots: Query<(&BuildHotbarSlot, &mut BorderColor, &mut Node)>,
    mut label: Query<&mut Text, With<BuildHotbarLabel>>,
    mut populated: Local<bool>,
) {
    // Swatch colours are static (set at spawn); only the highlight + label change
    // with the selection, so skip when the palette hasn't changed — but always
    // run the first time so the initial selection is highlighted.
    if *populated && !palette.is_changed() {
        return;
    }
    *populated = true;

    let selected = palette.selected_index();
    for (slot, mut border, mut node) in &mut slots {
        if slot.0 == selected {
            *border = BorderColor::all(Color::WHITE);
            node.border = UiRect::all(px(3));
        } else {
            *border = BorderColor::all(Color::srgba(0.0, 0.0, 0.0, 0.6));
            node.border = UiRect::all(px(2));
        }
    }

    if let Ok(mut text) = label.single_mut() {
        let entry = palette.selected();
        let kind = match entry.kind {
            BuildKind::Material(_) => "block",
            BuildKind::Prefab(_) => "prefab",
            BuildKind::Surface(_) => "fixture",
        };
        text.0 = format!(
            "▶ {}  [{}]   {}/{}   (scroll / 1-9 to pick)",
            entry.label,
            kind,
            selected + 1,
            palette.entries().len()
        );
    }
}
