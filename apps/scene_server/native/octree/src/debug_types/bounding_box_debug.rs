use rustler::NifStruct;

use crate::bounding_box::BoundingBox;

#[derive(Clone, Debug, NifStruct)]
#[module = "SceneServer.Native.Octree.BoundingBoxDebug"]
pub struct BoundingBoxDebug {
    pub center: Vec<f32>,
    pub half_size: Vec<f32>,
}

impl BoundingBoxDebug {
    pub fn new(data: BoundingBox) -> Self {
        Self {
            center: data.center.to_vec(),
            half_size: data.half_size.to_vec(),
        }
    }
}
