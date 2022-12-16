use nalgebra::Vector3;
use rapier3d_f64::prelude::{IntegrationParameters, BroadPhase, NarrowPhase, CollisionPipeline, RigidBodySet, ColliderSet,QueryPipeline};

pub struct PhySys {
    pub gravity: Vector3<f64>,
    pub integration_params: IntegrationParameters,
    pub pipeline: CollisionPipeline,
    pub queries: QueryPipeline,
    pub rigid_body_set: RigidBodySet,
    pub collider_set: ColliderSet,
    pub broad_phase: BroadPhase,
    pub narrow_phase: NarrowPhase,
}

impl PhySys {

    // Make a new physics system with the given gravity, using collision pipeline instead of physics pipeline
    pub fn new_sys_with_gravity(gravity: Vector3<f64>) -> PhySys {
        let integration_parameters = IntegrationParameters::default();
        let rigid_body_set = RigidBodySet::new();
        let collider_set = ColliderSet::new();
        let collision_pipeline = CollisionPipeline::new();
        let queries = QueryPipeline::new();
        let broad_phase = BroadPhase::new();
        let narrow_phase = NarrowPhase::new();

        PhySys { gravity, integration_params: integration_parameters, pipeline: collision_pipeline, queries, rigid_body_set, collider_set, broad_phase, narrow_phase, }
    }

    // detect collision using character's next moving location, return if collided
    pub fn step(&mut self) {
        self.pipeline.step(self.integration_params.prediction_distance, &mut self.broad_phase, &mut self.narrow_phase, &mut self.rigid_body_set, &mut self.collider_set, &(), &())

        // Save collision results into data structure
        
    }


}