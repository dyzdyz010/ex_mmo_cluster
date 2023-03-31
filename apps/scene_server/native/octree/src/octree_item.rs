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

impl OctreeItem {
    pub fn new(id: i64, pos: [f32; 3]) -> Self {
        OctreeItem {
            data: Arc::new(RwLock::new(OctreeItemData { id, pos })),
        }
    }

    pub fn update_position(&self, new_pos: [f32; 3]) {
        let mut item_data = self.data.write();
        (*item_data).pos = new_pos;
    }
}

impl PartialEq for OctreeItem {
    fn eq(&self, other: &Self) -> bool {
        self.data.read().id == other.data.read().id
    }
}