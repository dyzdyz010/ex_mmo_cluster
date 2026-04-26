//! `HudPlugin` — owns the HUD text component and the system that
//! re-renders it each frame from `WorldState` / `ChatState` / voxel state.

use bevy::ecs::system::SystemParam;
use bevy::prelude::*;

use crate::app::WorldState;
use crate::chat::{ChatInputText, ChatLogText, ChatState};
use crate::login::AppState;
use crate::voxel::VoxelWorld;

/// Marker for the primary HUD text node spawned by `app::setup`.
#[derive(Component)]
pub struct HudText;

pub struct HudPlugin;

impl Plugin for HudPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Update, update_hud_text.run_if(in_state(AppState::Game)));
    }
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
    world_state: Res<WorldState>,
    chat_state: Res<ChatState>,
    voxel_world: Res<VoxelWorld>,
    selection_state: Res<crate::voxel::plugin::VoxelSelectionState>,
    mut texts: HudTextParams,
) {
    let selected_target = world_state
        .selected_target_cid
        .and_then(|cid| world_state.remote_actor_identity.get(&cid))
        .map(|identity| format!("{} ({cid})", identity.name, cid = identity.cid))
        .unwrap_or_else(|| "none".to_string());
    let selected_point = world_state
        .selected_target_point
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
        world_state.status,
        world_state.control_transport.label(),
        world_state.movement_transport.label(),
        world_state.fast_lane_status,
        world_state
            .udp_endpoint
            .clone()
            .unwrap_or_else(|| "n/a".to_string()),
        world_state.remote_players.len(),
        world_state
            .remote_actor_identity
            .values()
            .filter(|identity| identity.is_npc())
            .count(),
        selected_target,
        selected_point,
        voxel_world.hotbar().selected.label,
        voxel_world.hotbar().selected_index + 1,
        voxel_selection,
        world_state.local_cid,
        world_state
            .local_position
            .map(|pos| format!("{:.1}, {:.1}, {:.1}", pos.x, pos.y, pos.z))
            .unwrap_or_else(|| "n/a".to_string()),
        world_state.local_hp,
        world_state.local_max_hp,
        world_state.local_alive,
        world_state
            .last_local_update_transport
            .map(|transport| transport.label().to_string())
            .unwrap_or_else(|| "n/a".to_string()),
        world_state
            .last_remote_move_transport
            .map(|transport| transport.label().to_string())
            .unwrap_or_else(|| "n/a".to_string()),
        world_state
            .last_rtt_ms
            .map(|value| format!("{value:.1} ms"))
            .unwrap_or_else(|| "n/a".to_string()),
        world_state
            .last_offset_ms
            .map(|value| format!("{value:.1} ms"))
            .unwrap_or_else(|| "n/a".to_string()),
        world_state
            .last_heartbeat_ts
            .map(|value| value.to_string())
            .unwrap_or_else(|| "n/a".to_string()),
    );

    let recent_chat = world_state
        .chat_log
        .iter()
        .rev()
        .take(5)
        .cloned()
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>();
    let recent_logs = world_state
        .logs
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
