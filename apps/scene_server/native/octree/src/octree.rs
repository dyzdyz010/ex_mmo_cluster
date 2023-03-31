use std::sync::Arc;

use crate::{octree_node::OctreeNode, octree_item::OctreeItem, bounding_box::BoundingBox};

#[derive(Clone, Debug)]
pub struct Octree {
    pub root: Arc<OctreeNode>,
}

impl Octree {
    pub fn new(bounds: BoundingBox, depth: u8, max_depth: u8, capacity: usize) -> Self {
        Octree {
            root: Arc::new(OctreeNode::new(bounds, depth, max_depth, capacity)),
        }
    }

    pub fn insert(&self, item: OctreeItem) {
        self.root.insert(item);
    }

    pub fn remove(&self, item: &OctreeItem) -> bool {
        self.root.remove(item)
    }

    pub fn get(&self, bounds: BoundingBox) -> Vec<OctreeItem> {
        self.root.get(bounds)
    }

    pub fn update_position(&self, item: &OctreeItem, new_pos: [f32; 3]) {
        self.root.update_item_position(item, new_pos);
    }
}