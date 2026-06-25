//! `HudPlugin` — owns the HUD text component and the system that
//! re-renders it each frame from the per-domain runtime resources
//! (`LocalPlayerState` / `RemotePlayers` / `NetTelemetry` / `GameLogs` /
//! `ConnectionState` / `ChatState` / voxel state).

use bevy::ecs::system::SystemParam;
use bevy::prelude::*;

use crate::app::schedule::ClientSet;
use crate::session::ConnectionState;
use crate::chat::{ChatInputText, ChatLogText, ChatState};
use crate::login::AppState;
use crate::net::NetTelemetry;
use crate::skill::TargetSelection;
use crate::voxel::VoxelWorld;
use crate::world::{LocalPlayerState, RemotePlayers};

use super::GameLogs;

/// Marker for the primary HUD text node spawned by [`spawn_hud`].
#[derive(Component)]
pub struct HudText;

/// Marker for the screen-centre crosshair container (so future systems can hide
/// it, e.g. while chat is open or in cinematic cutscenes).
#[derive(Component)]
pub struct Crosshair;

pub struct HudPlugin;

impl Plugin for HudPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, spawn_hud).add_systems(
            Update,
            update_hud_text
                .in_set(ClientSet::Render)
                .run_if(in_state(AppState::Game)),
        );
    }
}

/// Spawns the HUD text node and the centre-screen crosshair
/// (架构重整阶段3:从 `app::setup` 拆出到 hud 域)。
fn spawn_hud(mut commands: Commands) {
    commands.spawn((
        HudText,
        Text::new(""),
        TextFont {
            font_size: FontSize::Px(18.0),
            ..default()
        },
        TextColor(Color::WHITE),
        Node {
            position_type: PositionType::Absolute,
            top: px(12),
            left: px(12),
            ..default()
        },
    ));

    // Third-person + free-look mouse mode hides the OS cursor (camera audit C-S1),
    // so a small crosshair (two thin white bars centred at 50%/50% of the viewport)
    // shows where shots / interactions land. Pure UI so it stays anchored regardless
    // of camera motion.
    let arm_long: f32 = 14.0;
    let arm_short: f32 = 2.0;
    let bar_color = Color::srgba(1.0, 1.0, 1.0, 0.85);
    commands
        .spawn((
            Crosshair,
            Node {
                position_type: PositionType::Absolute,
                left: Val::Percent(50.0),
                top: Val::Percent(50.0),
                width: Val::Px(arm_long * 2.0),
                height: Val::Px(arm_long * 2.0),
                margin: UiRect {
                    left: Val::Px(-arm_long),
                    top: Val::Px(-arm_long),
                    ..default()
                },
                justify_content: JustifyContent::Center,
                align_items: AlignItems::Center,
                ..default()
            },
        ))
        .with_children(|parent| {
            // Horizontal bar.
            parent.spawn((
                Node {
                    position_type: PositionType::Absolute,
                    width: Val::Px(arm_long * 2.0),
                    height: Val::Px(arm_short),
                    ..default()
                },
                BackgroundColor(bar_color),
            ));
            // Vertical bar.
            parent.spawn((
                Node {
                    position_type: PositionType::Absolute,
                    width: Val::Px(arm_short),
                    height: Val::Px(arm_long * 2.0),
                    ..default()
                },
                BackgroundColor(bar_color),
            ));
        });
}

type HudTextSingle<'w, 's> = Single<
    'w,
    's,
    &'static mut Text,
    (With<HudText>, Without<ChatLogText>, Without<ChatInputText>),
>;
type ChatLogTextSingle<'w, 's> = Single<
    'w,
    's,
    &'static mut Text,
    (With<ChatLogText>, Without<HudText>, Without<ChatInputText>),
>;
type ChatInputTextSingle<'w, 's> = Single<
    'w,
    's,
    &'static mut Text,
    (With<ChatInputText>, Without<HudText>, Without<ChatLogText>),
>;

#[derive(SystemParam)]
struct HudTextParams<'w, 's> {
    hud: HudTextSingle<'w, 's>,
    chat_log_text: ChatLogTextSingle<'w, 's>,
    chat_input_text: ChatInputTextSingle<'w, 's>,
}

fn update_hud_text(
    local_player: Res<LocalPlayerState>,
    connection: Res<ConnectionState>,
    chat_state: Res<ChatState>,
    voxel_world: Res<VoxelWorld>,
    target: Res<TargetSelection>,
    logs: Res<GameLogs>,
    telemetry: Res<NetTelemetry>,
    remote: Res<RemotePlayers>,
    selection_state: Res<crate::voxel::plugin::VoxelSelectionState>,
    mut texts: HudTextParams,
    mut populated_once: Local<bool>,
) {
    // Audit E-L2: previously this system reformatted ~30 lines of text into
    // three Bevy `Text` components every frame, allocating dozens of
    // `String`s each time, even when nothing visible had changed. Bevy's
    // change-detection lets us short-circuit cleanly: if none of the input
    // resources changed since this system last ran, nothing on the HUD can
    // have changed either, so skip the work entirely.
    //
    // GUI-smoke 2026-04-26 follow-up: the early-return previously also fired
    // on the first frame after entering AppState::Game, leaving the HUD
    // text empty until the first network event mutated WorldState. Track a
    // `populated_once` flag so the first run always writes a full snapshot
    // even if no resource was mutated this exact frame.
    if *populated_once
        && !local_player.is_changed()
        && !connection.is_changed()
        && !chat_state.is_changed()
        && !voxel_world.is_changed()
        && !target.is_changed()
        && !logs.is_changed()
        && !telemetry.is_changed()
        && !remote.is_changed()
        && !selection_state.is_changed()
    {
        return;
    }
    *populated_once = true;

    let selected_target = target
        .cid
        .and_then(|cid| remote.identity.get(&cid))
        .map(|identity| format!("{} ({cid})", identity.name, cid = identity.cid))
        .unwrap_or_else(|| "none".to_string());
    let selected_point = target
        .point
        .map(|value| format!("{:.1}, {:.1}, {:.1}", value.x, value.y, value.z))
        .unwrap_or_else(|| "none".to_string());
    let voxel_selection = selection_state
        .selection
        .as_ref()
        .map(|selection| {
            format!(
                "hit={} adjacent={} normal={}",
                crate::voxel::format_macro_coord(selection.occupied_macro),
                crate::voxel::format_macro_coord(selection.adjacent_macro),
                crate::voxel::format_macro_coord(selection.face_normal)
            )
        })
        .unwrap_or_else(|| "none".to_string());

    texts.hud.0 = format!(
        "status: {}\ndemo: control={} | movement={} | fast-lane={}\nudp endpoint: {}\nAOI peers: {} (npcs: {})\nselected target: {}\nselected point: {}\nvoxel hotbar: {} ({})\nvoxel selection: {}\nlocal cid: {}\nposition: {}\nhp: {}/{} alive={}\nlast move ack: {}\nlast AOI move: {}\nrtt: {}\noffset: {}\nheartbeat: {}\ncontrols: WASD/Space move | mouse free-look (cursor locked) | Ctrl+wheel zoom | LMB/G break | RMB/F place | wheel/1-7 hotbar | Shift+1-4 skills | Shift+RMB target | Enter chat (releases cursor)",
        connection.status,
        telemetry.control_transport.label(),
        telemetry.movement_transport.label(),
        telemetry.fast_lane_status,
        telemetry.udp_endpoint
            .clone()
            .unwrap_or_else(|| "n/a".to_string()),
        remote.players.len(),
        remote.identity
            .values()
            .filter(|identity| identity.is_npc())
            .count(),
        selected_target,
        selected_point,
        voxel_world.hotbar().selected.label,
        voxel_world.hotbar().selected_index + 1,
        voxel_selection,
        local_player.cid,
        local_player.position
            .map(|pos| format!("{:.1}, {:.1}, {:.1}", pos.x, pos.y, pos.z))
            .unwrap_or_else(|| "n/a".to_string()),
        local_player.hp,
        local_player.max_hp,
        local_player.alive,
        telemetry.last_local_update_transport
            .map(|transport| transport.label().to_string())
            .unwrap_or_else(|| "n/a".to_string()),
        telemetry.last_remote_move_transport
            .map(|transport| transport.label().to_string())
            .unwrap_or_else(|| "n/a".to_string()),
        telemetry.last_rtt_ms
            .map(|value| format!("{value:.1} ms"))
            .unwrap_or_else(|| "n/a".to_string()),
        telemetry.last_offset_ms
            .map(|value| format!("{value:.1} ms"))
            .unwrap_or_else(|| "n/a".to_string()),
        telemetry.last_heartbeat_ts
            .map(|value| value.to_string())
            .unwrap_or_else(|| "n/a".to_string()),
    );

    let recent_chat = logs
        .chat
        .iter()
        .rev()
        .take(5)
        .cloned()
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>();
    let recent_logs = logs
        .general
        .iter()
        .rev()
        .take(4)
        .cloned()
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>();

    let mut sections = Vec::new();
    if !recent_chat.is_empty() {
        sections.push(format!("chat\n{}", recent_chat.join("\n")));
    }
    if !recent_logs.is_empty() {
        sections.push(format!("transport/demo\n{}", recent_logs.join("\n")));
    }
    texts.chat_log_text.0 = sections.join("\n\n");

    texts.chat_input_text.0 = if chat_state.enabled {
        format!("> {}_", chat_state.draft)
    } else {
        String::new()
    };
}
