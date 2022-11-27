use nalgebra::Vector3;
use rapier3d::prelude::{IntegrationParameters, IslandManager, BroadPhase, NarrowPhase, ImpulseJointSet, MultibodyJointSet, CCDSolver, vector, CollisionPipeline, PhysicsPipeline, RigidBodySet, ColliderSet};

pub struct PhySys {
    gravity: Vector3<f64>,
    integration_params: IntegrationParameters,
    pipeline: PhysicsPipeline,
    island_manager: IslandManager,
    broad_phase: BroadPhase,
    narrow_phase: NarrowPhase,
    impulse_joint_set: ImpulseJointSet,
    multibody_joint_set: MultibodyJointSet,
    ccd_solver: CCDSolver,
}

impl PhySys {
    pub fn new_sys() -> PhySys {
        let gravity: Vector3<f64> = vector![0.0, -9.81, 0.0];
        let integration_parameters = IntegrationParameters::default();
        // let mut physics_pipeline = PhysicsPipeline::new();
        let rigid_body_set = RigidBodySet::new();
        let collider_set = ColliderSet::new();
        let mut physics_pipeline = PhysicsPipeline::new();
        let mut collision_pipeline = CollisionPipeline::new();
        // collision_pipeline.step(prediction_distance, broad_phase, narrow_phase, bodies, colliders, hooks, events)
        let mut island_manager = IslandManager::new();
        let mut broad_phase = BroadPhase::new();
        let mut narrow_phase = NarrowPhase::new();
        let mut impulse_joint_set = ImpulseJointSet::new();
        let mut multibody_joint_set = MultibodyJointSet::new();
        let mut ccd_solver = CCDSolver::new();

        PhySys { gravity, integration_params: integration_parameters, pipeline: physics_pipeline, island_manager, broad_phase, narrow_phase, impulse_joint_set, multibody_joint_set, ccd_solver }
    }
}