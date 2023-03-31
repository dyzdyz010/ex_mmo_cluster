use rustler::NifStruct;

use crate::octree::Octree;

use super::octree_node_debug::OctreeNodeDebug;

#[derive(Clone, Debug, NifStruct)]
#[module = "SceneServer.Native.Octree.OctreeDebug"]
pub struct OctreeDebug {
    pub root: OctreeNodeDebug,
}

impl OctreeDebug {
    pub fn new(tree: Octree) -> Self {
        Self { root: OctreeNodeDebug::new((*(tree.root)).clone()) }
    }
}