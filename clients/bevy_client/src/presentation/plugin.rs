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
use crate::presentation::animation::{animated_scale, animation_state_from_velocity};
use crate::presentation::smoothing::smooth_translation;
use crate::voxel::VoxelWorld;
use crate::voxel::plugin::{ACTOR_HALF_HEIGHT, surface_center_y_at_render_xz};
use crate::world::remote_actor::RemoteActorKind;
use crate::world::remote_player::RemoteMotionSample;

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

fn sync_player_visuals(mut commands: Commands, mut params: PlayerVisualParams) {
    let mut entities_by_cid = HashMap::new();
    for (entity, visual, _transform, _material) in &params.existing {
        entities_by_cid.insert(visual.cid, entity);
    }

    let now_secs = params.time.elapsed_secs_f64();
    let mut desired = params
        .world_state
        .remote_players
        .iter()
        .map(|(&cid, state)| (cid, state.sample_motion(now_secs)))
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

    for (&cid, motion) in &desired {
        let target = actor_render_position(&params.voxel_world, motion.position);
        let animation =
            animation_state_from_velocity(motion.velocity, params.config.movement_speed);
        let actor_kind = params
            .world_state
            .remote_actor_identity
            .get(&cid)
            .map(|identity| identity.kind)
            .unwrap_or(RemoteActorKind::Player);
        let selected = params.world_state.selected_target_cid == Some(cid);
        let local = cid == params.world_state.local_cid;
        let material = actor_material_handle(
            &params.assets,
            local,
            selected,
            actor_kind,
            animation.moving,
        );

        if let Some(entity) = entities_by_cid.remove(&cid) {
            if let Ok((_entity, _visual, mut transform, mut existing_material)) =
                params.existing.get_mut(entity)
            {
                transform.translation = if local {
                    target
                } else {
                    smooth_translation(
                        transform.translation,
                        target,
                        params.time.delta_secs(),
                        VISUAL_SMOOTHING_SPEED,
                        VISUAL_SNAP_DISTANCE,
                    )
                };
                transform.scale =
                    animated_scale(transform.scale, animation, params.time.delta_secs());
                *existing_material = MeshMaterial3d(material);
            }
        } else {
            let scale = if matches!(actor_kind, RemoteActorKind::Npc) {
                Vec3::new(30.0, 28.0, 24.0)
            } else {
                Vec3::new(24.0, 36.0, 24.0)
            };

            commands.spawn((
                PlayerVisual { cid },
                Mesh3d(params.assets.player_mesh.clone()),
                MeshMaterial3d(material),
                Transform::from_translation(target).with_scale(
                    scale * animated_scale(Vec3::ONE, animation, params.time.delta_secs()),
                ),
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
