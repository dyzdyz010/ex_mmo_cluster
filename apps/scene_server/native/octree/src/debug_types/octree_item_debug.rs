use rustler::NifStruct;

use crate::octree_item::OctreeItem;



#[derive(Clone, Debug, NifStruct)]
#[module = "SceneServer.Native.Octree.OctreeItemDebug"]
pub struct OctreeItemDebug {
    pub id: i64,
    pub pos: Vec<f32>,
}

impl OctreeItemDebug {
    pub fn new(item: &OctreeItem) -> Self {
        let data = item.data.read();
        Self {
            id: data.id,
            pos: data.pos.to_vec(),
        }
    }
}