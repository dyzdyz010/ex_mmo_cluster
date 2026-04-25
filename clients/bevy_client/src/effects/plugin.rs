//! `EffectPlugin` — owns transient `EffectVisual` entities (projectiles,
//! AOE rings, melee/chain arcs, impact pulses) and their gizmo overlays.
//!
//! Spawning is driven by `NetworkPlugin` consuming `NetworkEvent::EffectEvent`
//! — that's the only producer; the systems here only animate and despawn.

use bevy::prelude::*;

use crate::app::sim_to_render_position;
use crate::login::AppState;
use crate::protocol::EffectCueKind;

/// Marker + payload for one in-flight effect cue (projectile, AOE ring,
/// arc, etc.).
#[derive(Component)]
pub struct EffectVisual {
    pub kind: EffectCueKind,
    pub timer: Timer,
    pub origin: Vec3,
    pub target: Vec3,
    pub radius: f32,
}

pub struct EffectPlugin;

impl Plugin for EffectPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            (update_effect_visuals, draw_effect_gizmos).run_if(in_state(AppState::Game)),
        );
    }
}

fn update_effect_visuals(
    mut commands: Commands,
    time: Res<Time>,
    mut effects: Query<(Entity, &mut Transform, &mut EffectVisual)>,
) {
    for (entity, mut transform, mut effect) in &mut effects {
        effect.timer.tick(time.delta());
        let progress = effect.timer.fraction();
        let translation =
            effect_interpolated_translation(effect.kind, effect.origin, effect.target, progress);
        transform.translation = sim_to_render_position(translation) + Vec3::Y * 10.0;

        if effect.timer.is_finished() {
            commands.entity(entity).despawn();
        }
    }
}

fn draw_effect_gizmos(effects: Query<&EffectVisual>, mut gizmos: Gizmos) {
    for effect in &effects {
        let progress = effect.timer.fraction();
        let color = effect_runtime_color(effect.kind, progress);
        let origin = sim_to_render_position(effect.origin) + Vec3::Y * 18.0;
        let target = sim_to_render_position(effect.target) + Vec3::Y * 18.0;
        let current = sim_to_render_position(effect_interpolated_translation(
            effect.kind,
            effect.origin,
            effect.target,
            progress,
        )) + Vec3::Y * 18.0;

        match effect.kind {
            EffectCueKind::Projectile => {
                gizmos.line(origin, current, color);
                gizmos.sphere(current, 8.0, color);
            }
            EffectCueKind::MeleeArc | EffectCueKind::ChainArc => {
                gizmos.line(origin, target, color);
                gizmos.sphere(current, 5.0, color);
            }
            EffectCueKind::AoeRing => {
                gizmos.circle(
                    Isometry3d::new(target, Quat::from_rotation_arc(Vec3::Z, Vec3::Y)),
                    effect.radius.max(24.0),
                    color,
                );
            }
            EffectCueKind::ImpactPulse | EffectCueKind::Unknown(_) => {
                gizmos.sphere(current, 10.0 + progress * 22.0, color);
            }
        }
    }
}

fn effect_color(kind: EffectCueKind) -> Color {
    match kind {
        EffectCueKind::MeleeArc => Color::srgba(1.0, 0.82, 0.3, 0.75),
        EffectCueKind::Projectile => Color::srgba(0.45, 0.95, 1.0, 0.9),
        EffectCueKind::AoeRing => Color::srgba(0.8, 0.45, 1.0, 0.55),
        EffectCueKind::ChainArc => Color::srgba(1.0, 0.95, 0.55, 0.8),
        EffectCueKind::ImpactPulse => Color::srgba(1.0, 0.55, 0.35, 0.7),
        EffectCueKind::Unknown(_) => Color::srgba(1.0, 1.0, 1.0, 0.5),
    }
}

/// Initial render translation when an effect cue is first spawned.
///
/// Pub so `NetworkPlugin` can place the entity near origin (projectiles,
/// melee, chains) or near target (AOE, impact, unknown) before the timer
/// updates.
pub fn effect_spawn_translation(kind: EffectCueKind, origin: Vec3, target: Vec3) -> Vec3 {
    match kind {
        EffectCueKind::Projectile | EffectCueKind::MeleeArc | EffectCueKind::ChainArc => origin,
        _ => target,
    }
}

fn effect_interpolated_translation(
    kind: EffectCueKind,
    origin: Vec3,
    target: Vec3,
    progress: f32,
) -> Vec3 {
    match kind {
        EffectCueKind::Projectile => origin.lerp(target, progress),
        EffectCueKind::MeleeArc => origin.lerp(target, 0.35),
        EffectCueKind::ChainArc => origin.lerp(target, 0.5),
        _ => target,
    }
}

fn effect_runtime_color(kind: EffectCueKind, progress: f32) -> Color {
    let mut color = effect_color(kind);
    let alpha = color.to_srgba().alpha;
    color.set_alpha((1.0 - progress).clamp(0.0, 1.0) * alpha);
    color
}
