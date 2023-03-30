use crate::octree_item::OctreeItem;

#[derive(Clone, Debug)]
pub struct BoundingBox {
    pub center: [f32; 3],
    pub half_size: [f32; 3],
}

impl BoundingBox {
    pub fn new(center: [f32; 3], half_size: [f32; 3]) -> Self {
        Self { center, half_size }
    }

    fn contains_point(&self, point: &[f32; 3]) -> bool {
        for i in 0..3 {
            if point[i] < self.center[i] - self.half_size[i]
                || point[i] > self.center[i] + self.half_size[i]
            {
                return false;
            }
        }
        true
    }

    pub fn contains_object(&self, object: &OctreeItem) -> bool {
        // 假设Object结构体有一个方法`position()`，返回物体的位置（中心点）。
        self.contains_point(&object.data.read().pos)
    }

    pub fn intersects(&self, other: &BoundingBox) -> bool {
        for i in 0..3 {
            if (self.center[i] + self.half_size[i]) < (other.center[i] - other.half_size[i])
                || (self.center[i] - self.half_size[i]) > (other.center[i] + other.half_size[i])
            {
                return false;
            }
        }
        true
    }
}
