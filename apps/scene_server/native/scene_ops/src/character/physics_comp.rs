use nalgebra::Vector3;
use rapier3d_f64::{
    control::KinematicCharacterController,
    prelude::{ColliderBuilder, ColliderHandle, QueryFilter},
};

use crate::physics::physics_system::PhySys;

use super::types::Vector;

#[derive(Clone, Copy)]
pub struct PhysicsComp {
    character_controller: KinematicCharacterController,
    // pub rigid_body_handle: RigidBodyHandle,
    collider_handle: ColliderHandle,
}

impl PhysicsComp {
    // New with default data
    pub fn new(location: Vector, physys: &mut PhySys) -> PhysicsComp {
        // Phase A2 Step 5:旧版 capsule_z(0.3, 0.15) 用 SI(米)单位,而世界
        // 其余部分(player_character.ex / movement_core / web_client 渲染)
        // 都是 1 unit = 1 cm。混用单位会让 collider 实际只有 60cm 高 30cm 直径
        // 的"针尖大"形状坐在 cm 坐标里。movement 主路径走 movement_core 不读
        // capsule 形状,所以一直没出事;为日后 npc / chunk 体素碰撞重新启用
        // rapier character controller 时形状对得上,改 cm 单位 = 角色 1.7m 高
        // 0.6m 直径(half-height 85, radius 30,跟 web_client AvatarConstants 同步)。
        let collider = ColliderBuilder::capsule_z(85.0, 30.0)
            .translation(Vector3::new(location.x, location.y, location.z))
            .build();
        let collider_handle = physys.collider_set.insert(collider);
        let character_controller = KinematicCharacterController::default();

        PhysicsComp {
            character_controller,
            collider_handle
        }
    }

    // Move function
    pub fn controller_move(&mut self, translation: Vector, physys: &mut PhySys) -> Vector {
        let collider = &physys.collider_set[self.collider_handle];
        let desired_translation = Vector3::new(translation.x, translation.y, translation.z);

        let corrected_movement = self.character_controller.move_shape(
            physys.integration_params.dt,
            &physys.rigid_body_set,
            &physys.collider_set,
            &physys.queries,
            physys.collider_set[self.collider_handle].shape(),
            collider.position(),
            desired_translation,
            QueryFilter::default().exclude_collider(self.collider_handle),
            |_| {},
        );

        let collider = &mut physys.collider_set[self.collider_handle];
        collider.set_translation(collider.translation() + corrected_movement.translation);

        return self.get_location(&physys);
    }

    // Get current location
    pub fn get_location(&self, physys: &PhySys) -> Vector {
        let collider = &physys.collider_set[self.collider_handle];
        return Vector{x: collider.position().translation.x, y: collider.position().translation.y, z: collider.position().translation.z};
    }
}
