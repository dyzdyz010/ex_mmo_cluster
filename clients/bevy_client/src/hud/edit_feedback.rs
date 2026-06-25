//! Center-screen **edit feedback flash**: when the server rejects a voxel edit
//! (`VoxelIntentResult` with a failure `result_code`), surface a short localized
//! message so the player knows *why* the build/dig did nothing — instead of the
//! edit silently failing (the "放了几个方块后增删没反应" symptom: the edit landed
//! outside the assigned region and came back `:unassigned_chunk`, but nothing in
//! the UI reflected it).
//!
//! The actual wiring (reading `NetworkEvent::Voxel(VoxelIntentResult)` and calling
//! [`EditFeedback::flash_failure`]) lives in `net::plugin::poll_network_events`,
//! which already drains the voxel inbox; this module owns the resource, the
//! reason→中文 mapping, and the fading HUD text.

use bevy::prelude::*;

use crate::login::AppState;

/// How long a flashed message stays fully visible before it starts fading.
const HOLD_SECS: f32 = 2.0;
/// Fade-out duration appended after the hold — total on-screen time is the sum.
const FADE_SECS: f32 = 1.0;

/// Transient "your edit was rejected" banner state. Lives for the whole session
/// (inserted at plugin build) so `poll_network_events` can write to it the moment
/// a failure ACK arrives, regardless of UI lifecycle.
#[derive(Resource, Default)]
pub struct EditFeedback {
    text: String,
    /// Time (in `Time::elapsed_secs`) at which the banner is fully gone.
    expires_at: f32,
    /// Time at which fade-out begins (`expires_at - FADE_SECS`).
    fade_start: f32,
}

impl EditFeedback {
    /// Flash a rejection. `reason` is the raw server string (an `inspect/1` of the
    /// server-side atom, e.g. `":unassigned_chunk"`); `now` is `time.elapsed_secs()`.
    pub fn flash_failure(&mut self, reason: &str, now: f32) {
        self.text = localize_reason(reason);
        self.fade_start = now + HOLD_SECS;
        self.expires_at = now + HOLD_SECS + FADE_SECS;
    }

    /// Alpha multiplier for the banner at `now`, 0.0 once fully expired.
    fn alpha(&self, now: f32) -> f32 {
        if now >= self.expires_at {
            0.0
        } else if now <= self.fade_start {
            1.0
        } else {
            1.0 - (now - self.fade_start) / FADE_SECS
        }
    }
}

#[derive(Component)]
struct EditFeedbackText;

pub struct EditFeedbackPlugin;

impl Plugin for EditFeedbackPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<EditFeedback>()
            .add_systems(OnEnter(AppState::Game), setup_edit_feedback)
            .add_systems(
                Update,
                update_edit_feedback.run_if(in_state(AppState::Game)),
            );
    }
}

/// Maps a server reason (raw `inspect/1` output) to a player-facing 中文 message.
///
/// Server failures arrive as `inspect(reason)` (see `ws_connection.ex`
/// `voxel_edit_intent_result_error/2`), so an atom reason like `:unassigned_chunk`
/// is the literal string `":unassigned_chunk"`. We strip the leading `:` and a
/// surrounding `{...}`/quotes best-effort, then match the well-known cases; the
/// fallback echoes whatever the server said so nothing is ever swallowed.
fn localize_reason(reason: &str) -> String {
    let key = reason.trim().trim_start_matches(':');
    match key {
        "unassigned_chunk" => "✗ 该区域尚未开放(超出可建造范围)".to_string(),
        "chunk_out_of_bounds" => "✗ 超出区域边界，无法在此处建造".to_string(),
        "out_of_reach" => "✗ 超出可达距离".to_string(),
        "occupied" => "✗ 目标位置已被占用".to_string(),
        "stale_chunk_version" | "stale_cell_hash" => "✗ 数据已过期，请重试".to_string(),
        "rate_limited" => "✗ 操作过于频繁，请稍候".to_string(),
        "no_owner" | "no_scene_owner" => "✗ 该区域暂无服务节点接管".to_string(),
        other => format!("✗ 编辑被拒：{other}"),
    }
}

fn setup_edit_feedback(mut commands: Commands) {
    // Full-width band a little above screen centre, text centred — reads over the
    // crosshair without colliding with the bottom hotbar or top-left status HUD.
    commands
        .spawn(Node {
            position_type: PositionType::Absolute,
            top: Val::Percent(42.0),
            left: px(0),
            width: Val::Percent(100.0),
            justify_content: JustifyContent::Center,
            ..default()
        })
        .with_children(|band| {
            // Spawned even while empty so the text node exists before the first
            // flash; `update_edit_feedback` toggles its colour alpha.
            band.spawn((
                EditFeedbackText,
                Text::new(""),
                TextFont {
                    font_size: FontSize::Px(24.0),
                    ..default()
                },
                TextColor(Color::srgba(1.0, 0.4, 0.35, 0.0)),
            ));
        });
}

fn update_edit_feedback(
    time: Res<Time>,
    feedback: Res<EditFeedback>,
    mut query: Query<(&mut Text, &mut TextColor), With<EditFeedbackText>>,
) {
    let now = time.elapsed_secs();
    let alpha = feedback.alpha(now);
    let Ok((mut text, mut color)) = query.single_mut() else {
        return;
    };
    if alpha <= 0.0 {
        if !text.0.is_empty() {
            text.0.clear();
        }
        color.0 = color.0.with_alpha(0.0);
        return;
    }
    if text.0 != feedback.text {
        text.0 = feedback.text.clone();
    }
    color.0 = Color::srgba(1.0, 0.4, 0.35, alpha);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn localizes_known_reasons_and_strips_colon() {
        assert!(localize_reason(":unassigned_chunk").contains("尚未开放"));
        assert!(localize_reason("unassigned_chunk").contains("尚未开放"));
        assert!(localize_reason(":stale_chunk_version").contains("过期"));
        // Unknown reasons echo verbatim so nothing is hidden from the player.
        assert!(localize_reason(":weird_new_reason").contains("weird_new_reason"));
    }

    #[test]
    fn alpha_holds_then_fades() {
        let mut fb = EditFeedback::default();
        fb.flash_failure(":unassigned_chunk", 100.0);
        assert_eq!(fb.alpha(100.0), 1.0); // freshly flashed
        assert_eq!(fb.alpha(101.0), 1.0); // still within hold
        assert!((fb.alpha(102.5) - 0.5).abs() < 1e-4); // mid-fade
        assert_eq!(fb.alpha(103.0), 0.0); // expired
        assert_eq!(fb.alpha(200.0), 0.0); // long expired
    }
}
