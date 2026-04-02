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
        let collider = ColliderBuilder::capsule_z(0.3, 0.15)
            .translation(Vector3::new(location.x, location.y, location.z).into())
            .build();
        let collider_handle = physys.collider_set.insert(collider);
        physys.sync_colliders(&[collider_handle], &[]);
        let character_controller = KinematicCharacterController::default();

        PhysicsComp {
            character_controller,
            collider_handle
        }
    }

    // Move function
    pub fn controller_move(&mut self, translation: Vector, physys: &mut PhySys) -> Vector {
        let corrected_movement = {
            let collider = &physys.collider_set[self.collider_handle];
            let desired_translation = Vector3::new(translation.x, translation.y, translation.z).into();
            let query_pipeline =
                physys.query_pipeline(QueryFilter::default().exclude_collider(self.collider_handle));

            self.character_controller.move_shape(
                physys.integration_params.dt,
                &query_pipeline,
                collider.shape(),
                collider.position(),
                desired_translation,
                |_| {},
            )
        };

        let collider = &mut physys.collider_set[self.collider_handle];
        collider.set_translation(collider.translation() + corrected_movement.translation);
        physys.sync_colliders(&[self.collider_handle], &[]);

        return self.get_location(&physys);
    }

    // Get current location
    pub fn get_location(&self, physys: &PhySys) -> Vector {
        let collider = &physys.collider_set[self.collider_handle];
        return Vector{x: collider.position().translation.x, y: collider.position().translation.y, z: collider.position().translation.z};
    }
}
