//! `PresentationPlugin` — owns local + remote player visuals (the actor
//! cubes) and the actor-material lookup. The mesh and material handles
//! are created in `app::setup` and stashed in [`crate::app::SceneRenderAssets`].

use std::collections::HashMap;

use bevy::ecs::system::SystemParam;
use bevy::prelude::*;

use crate::app::{
    LocalRenderPrediction, SceneRenderAssets, VISUAL_SMOOTHING_SPEED, VISUAL_SNAP_DISTANCE,
    WorldState,
};
use crate::config::ClientConfig;
use crate::login::AppState;
use crate::observe::ClientObserver;
use crate::presentation::animation::{animated_scale, animation_state_from_velocity};
use crate::presentation::smoothing::smooth_translation;
use crate::voxel::VoxelWorld;
use crate::voxel::plugin::{ACTOR_HALF_HEIGHT, surface_center_y_at_render_xz};
use crate::world::remote_actor::RemoteActorKind;
use crate::world::remote_player::{RemoteMotionSample, RemoteSamplePath};

/// Marker + payload component for one in-world actor visual cube.
#[derive(Component)]
pub struct PlayerVisual {
    pub cid: i64,
}

pub struct PresentationPlugin;

impl Plugin for PresentationPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Update, sync_player_visuals.run_if(in_state(AppState::Game)));
    }
}

#[derive(SystemParam)]
struct PlayerVisualParams<'w, 's> {
    time: Res<'w, Time>,
    world_state: Res<'w, WorldState>,
    local_render_prediction: Res<'w, LocalRenderPrediction>,
    config: Res<'w, ClientConfig>,
    voxel_world: Res<'w, VoxelWorld>,
    assets: Res<'w, SceneRenderAssets>,
    observer: Res<'w, ClientObserver>,
    existing: Query<
        'w,
        's,
        (
            Entity,
            &'static PlayerVisual,
            &'static mut Transform,
            &'static mut MeshMaterial3d<StandardMaterial>,
        ),
    >,
}

fn sync_player_visuals(
    mut commands: Commands,
    mut params: PlayerVisualParams,
    // Audit D-S1: explicit "prior local_cid" so that if the cid changes
    // between frames (e.g. cross-scene rejoin) we can deterministically
    // despawn the visual tied to the previous cid before this frame's
    // spawn loop runs. The general despawn loop at the bottom already
    // catches this in the steady state, but doing it explicitly here
    // closes the "spawn-new + despawn-old in the same Commands batch"
    // case where Bevy could render both visuals for one frame.
    mut previous_local_cid: Local<Option<i64>>,
) {
    let current_local_cid = params.world_state.local_cid;
    let mut entities_by_cid = HashMap::new();
    for (entity, visual, _transform, _material) in &params.existing {
        entities_by_cid.insert(visual.cid, entity);
    }

    if let Some(prior) = *previous_local_cid
        && prior != current_local_cid
        && let Some(entity) = entities_by_cid.remove(&prior)
    {
        commands.entity(entity).despawn();
    }
    *previous_local_cid = Some(current_local_cid);

    let now_secs = params.time.elapsed_secs_f64();
    let mut desired = params
        .world_state
        .remote_players
        .iter()
        .map(|(&cid, state)| {
            let (sample, path) = state.sample_motion_with_path(now_secs);
            // Audit D-S2: emit a structured event when we fall through to
            // the orphaned-extrapolation branch — that is the path that
            // produces visible "snap" jumps when the next snapshot finally
            // arrives. Operators tracking lag spikes can grep for it.
            if matches!(path, RemoteSamplePath::OrphanedExtrapolation) && params.observer.enabled()
            {
                params.observer.emit(
                    "presentation",
                    "remote_orphaned_extrapolation",
                    &[
                        ("cid", cid.to_string()),
                        (
                            "position",
                            format!(
                                "{:.1},{:.1},{:.1}",
                                sample.position.x, sample.position.y, sample.position.z
                            ),
                        ),
                    ],
                );
            }
            (cid, sample)
        })
        .collect::<HashMap<_, _>>();
    if let Some(local) = params
        .local_render_prediction
        .render_state
        .as_ref()
        .map(|state| RemoteMotionSample {
            position: state.position,
            velocity: state.velocity,
        })
        .or_else(|| {
            params
                .world_state
                .local_position
                .map(|local| RemoteMotionSample {
                    position: local,
                    velocity: params.world_state.local_velocity,
                })
        })
    {
        desired.insert(params.world_state.local_cid, local);
    }

    let delta_secs = params.time.delta_secs();
    for (&cid, motion) in &desired {
        let target = actor_render_position(&params.voxel_world, motion.position);
        let actor_kind = params
            .world_state
            .remote_actor_identity
            .get(&cid)
            .map(|identity| identity.kind)
            .unwrap_or(RemoteActorKind::Player);
        let selected = params.world_state.selected_target_cid == Some(cid);
        let local = cid == params.world_state.local_cid;

        if let Some(entity) = entities_by_cid.remove(&cid) {
            if let Ok((_entity, _visual, mut transform, mut existing_material)) =
                params.existing.get_mut(entity)
            {
                let prev_translation = transform.translation;
                transform.translation = if local {
                    target
                } else {
                    smooth_translation(
                        prev_translation,
                        target,
                        delta_secs,
                        VISUAL_SMOOTHING_SPEED,
                        VISUAL_SNAP_DISTANCE,
                    )
                };
                // Audit D-M1: derive animation velocity from the *rendered*
                // translation delta instead of the buffered/extrapolated
                // motion.velocity. This keeps legs and body in sync after a
                // teleport: snap → rendered velocity is immediately near
                // zero (smoothing held position) so the actor stops idling
                // through the slide.
                let animation_velocity = if local || delta_secs <= f32::EPSILON {
                    motion.velocity
                } else {
                    (transform.translation - prev_translation) / delta_secs
                };
                let animation =
                    animation_state_from_velocity(animation_velocity, params.config.movement_speed);
                let material = actor_material_handle(
                    &params.assets,
                    local,
                    selected,
                    actor_kind,
                    animation.moving,
                );
                transform.scale = animated_scale(transform.scale, animation, delta_secs);
                *existing_material = MeshMaterial3d(material);
            }
        } else {
            // Fresh spawn: no previous translation to differentiate against,
            // so trust motion.velocity for the initial animation frame.
            let animation =
                animation_state_from_velocity(motion.velocity, params.config.movement_speed);
            let material = actor_material_handle(
                &params.assets,
                local,
                selected,
                actor_kind,
                animation.moving,
            );
            let scale = if matches!(actor_kind, RemoteActorKind::Npc) {
                Vec3::new(30.0, 28.0, 24.0)
            } else {
                Vec3::new(24.0, 36.0, 24.0)
            };

            commands.spawn((
                PlayerVisual { cid },
                Mesh3d(params.assets.player_mesh.clone()),
                MeshMaterial3d(material),
                Transform::from_translation(target)
                    .with_scale(scale * animated_scale(Vec3::ONE, animation, delta_secs)),
            ));
        }
    }

    for (cid, entity) in entities_by_cid {
        if cid != params.world_state.local_cid {
            commands.entity(entity).despawn();
        }
    }
}

/// Renders an actor's sim-coord position into the voxel render space and
/// snaps it to the top of the supporting voxel column. Used by both the
/// presentation layer (player visual sync) and the camera follow target.
pub fn actor_render_position(voxel_world: &VoxelWorld, sim_position: Vec3) -> Vec3 {
    let render = crate::app::sim_to_render_position(sim_position);
    let grounded_y =
        surface_center_y_at_render_xz(voxel_world, render.x, render.z, ACTOR_HALF_HEIGHT, render.y);
    Vec3::new(render.x, grounded_y, render.z)
}

fn actor_material_handle(
    assets: &SceneRenderAssets,
    local: bool,
    selected: bool,
    actor_kind: RemoteActorKind,
    moving: bool,
) -> Handle<StandardMaterial> {
    if local {
        assets.local_player_material.clone()
    } else if selected {
        assets.selected_actor_material.clone()
    } else if matches!(actor_kind, RemoteActorKind::Npc) {
        assets.npc_material.clone()
    } else if moving {
        assets.moving_player_material.clone()
    } else {
        assets.remote_player_material.clone()
    }
}
