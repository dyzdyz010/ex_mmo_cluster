use std::sync::Arc;

use parking_lot::RwLock;

#[derive(Clone, Debug)]
pub struct OctreeItemData {
    pub id: i64,
    pub pos: [f32; 3],
}

#[derive(Clone, Debug)]
pub struct OctreeItem {
    pub data: Arc<RwLock<OctreeItemData>>,
}
