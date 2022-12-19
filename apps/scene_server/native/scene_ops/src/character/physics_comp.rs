use nalgebra::Vector3;
use rapier3d_f64::{
    control::KinematicCharacterController,
    prelude::{ColliderBuilder, ColliderHandle, QueryFilter},
};

use crate::physics::pipeline::PhySys;

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
        // let rigid_body = RigidBodyBuilder::kinematic_position_based().translation(Vector3::new(location.x, location.y, location.z)).build();
        // let rigid_body_handle = physys.rigid_body_set.insert(rigid_body);
        let collider = ColliderBuilder::capsule_z(0.3, 0.15)
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
