use nalgebra::Vector3;
use rapier3d_f64::{control::KinematicCharacterController, prelude::{RigidBody, Collider, RigidBodyBuilder, ColliderBuilder, Isometry, RigidBodyHandle, QueryFilter}};

use crate::physics::pipeline::PhySys;

use super::types::Vector;

pub struct PhysicsComp {
    pub character_controller: KinematicCharacterController,
    pub rigid_body_handle: RigidBodyHandle,
    pub collider: Collider
}

impl PhysicsComp {
    // New with default data
    pub fn new(location: Vector, physys: &PhySys) -> PhysicsComp {
        let rigid_body = RigidBodyBuilder::kinematic_position_based().translation(Vector3::new(location.x, location.y, location.z)).build();
        let rigid_body_handle = physys.rigid_body_set.insert(rigid_body);
        let collider = ColliderBuilder::capsule_z(0.3, 0.15).translation(Vector3::new(location.x, location.y, location.z)).build();
        let character_controller = KinematicCharacterController::default();

        PhysicsComp { character_controller, rigid_body_handle, collider }
    }

    // Move function
    pub fn controller_move(&mut self, location: Vector, physys: &PhySys) {
        let desired_translation = Vector3::new(location.x, location.y, location.z);

        let corrected_movement = self.character_controller.move_shape(physys.integration_params.dt, &physys.rigid_body_set, &physys.collider_set, &physys.queries, self.collider.shape(), self.collider.position(), desired_translation, QueryFilter::default().exclude_rigid_body(self.rigid_body_handle), |_| {});

        self.rigid_body_handle.set_position(Isometry::translation(corrected_movement.x, corrected_movement.y, corrected_movement.z));
    }
}