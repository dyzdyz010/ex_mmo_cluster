use std::sync::{Arc};
use parking_lot::RwLock;

use crate::{octree_item::OctreeItem, bounding_box::BoundingBox};

pub struct OctreeNode {
    boundary: BoundingBox,
    children: RwLock<Option<Vec<Arc<OctreeNode>>>>,
    objects: RwLock<Vec<OctreeItem>>,
    depth: u8,
    max_depth: u8,
    capacity: usize,
}

