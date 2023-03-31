use rustler::NifTuple;

// 三维向量
#[derive(NifTuple, Clone, Debug, Copy, PartialEq)]
pub struct Vector3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vector3 {
    pub fn to_arr(&self) -> [f32; 3] {
        [self.x, self.y, self.z]
    }
}