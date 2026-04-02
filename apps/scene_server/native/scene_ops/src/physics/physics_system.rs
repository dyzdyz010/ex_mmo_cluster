use rapier3d_f64::prelude::{
    BroadPhaseBvh, ColliderHandle, ColliderSet, IntegrationParameters, NarrowPhase, QueryFilter,
    QueryPipeline, RigidBodySet,
};

pub struct PhySys {
    pub integration_params: IntegrationParameters,
    pub rigid_body_set: RigidBodySet,
    pub collider_set: ColliderSet,
    pub broad_phase: BroadPhaseBvh,
    pub narrow_phase: NarrowPhase,
}

impl PhySys {
    pub fn new() -> PhySys {
        let integration_parameters = IntegrationParameters::default();
        let rigid_body_set = RigidBodySet::new();
        let collider_set = ColliderSet::new();
        let broad_phase = BroadPhaseBvh::new();
        let narrow_phase = NarrowPhase::new();

        PhySys {
            integration_params: integration_parameters,
            rigid_body_set,
            collider_set,
            broad_phase,
            narrow_phase,
        }
    }

    pub fn query_pipeline<'a>(&'a self, filter: QueryFilter<'a>) -> QueryPipeline<'a> {
        self.broad_phase.as_query_pipeline(
            self.narrow_phase.query_dispatcher(),
            &self.rigid_body_set,
            &self.collider_set,
            filter,
        )
    }

    pub fn sync_colliders(
        &mut self,
        modified_colliders: &[ColliderHandle],
        removed_colliders: &[ColliderHandle],
    ) {
        let mut events = Vec::new();

        self.broad_phase.update(
            &self.integration_params,
            &self.collider_set,
            &self.rigid_body_set,
            modified_colliders,
            removed_colliders,
            &mut events,
        );
    }
}
