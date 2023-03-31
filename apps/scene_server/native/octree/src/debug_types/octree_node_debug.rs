use rustler::NifStruct;

use crate::octree_node::OctreeNode;

use super::{bounding_box_debug::BoundingBoxDebug, octree_item_debug::OctreeItemDebug};

#[derive(Clone, Debug, NifStruct)]
#[module = "SceneServer.Native.Octree.OctreeNodeDebug"]
pub struct OctreeNodeDebug {
    pub boundary: BoundingBoxDebug,
    pub children: Option<Vec<OctreeNodeDebug>>,
    pub objects: Vec<OctreeItemDebug>,
    pub depth: u8,
    pub max_depth: u8,
    pub capacity: usize,
}

impl OctreeNodeDebug {
    pub fn new(node: OctreeNode) -> Self {
        Self {
            boundary: BoundingBoxDebug::new(node.data.read().boundary),
            children: node.data.read().children.as_ref().map(|children| {
                children
                    .into_iter()
                    .map(|child| OctreeNodeDebug::new(child.clone()))
                    .collect()
            }),
            objects: node
                .data
                .read()
                .objects
                .clone()
                .into_iter()
                .map(|object| OctreeItemDebug::new(&object))
                .collect(),
            depth: node.data.read().depth,
            max_depth: node.data.read().max_depth,
            capacity: node.data.read().capacity,
        }
    }
}
