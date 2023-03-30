use parking_lot::RwLock;
use std::{convert::TryInto, sync::Arc};

use crate::{bounding_box::BoundingBox, octree_item::OctreeItem};

#[derive(Clone, Debug)]
pub struct OctreeNodeData {
    pub boundary: BoundingBox,
    pub children: Option<[OctreeNode; 8]>,
    pub objects: Vec<OctreeItem>,
    pub depth: u8,
    pub max_depth: u8,
    pub capacity: usize,
}

#[derive(Clone, Debug)]
pub struct OctreeNode {
    data: Arc<RwLock<OctreeNodeData>>,
}

impl OctreeNode {
    pub fn new(boundary: BoundingBox, depth: u8, max_depth: u8, capacity: usize) -> Self {
        // print!("boundary: {:#?}", boundary);
        Self {
            data: Arc::new(RwLock::new(OctreeNodeData {
                boundary,
                children: None,
                objects: Vec::with_capacity(capacity),
                depth,
                max_depth,
                capacity,
            })),
        }
    }

    pub fn insert(&self, item: OctreeItem) {
        // print!("objects: {:#?}", self);
        let read_node_data = self.data.read();

        // 如果当前节点没有子节点并且未达到容量限制，直接将对象添加到当前节点的对象列表中
        if read_node_data.children.is_none()
            && read_node_data.objects.len() < read_node_data.capacity
        {
            drop(read_node_data);
            // let mut write_node_data = self.data.upgradable_read();
            let mut write_node_data = self.data.write();
            (*write_node_data).objects.push(item);
        } else {
            // 如果当前节点没有子节点，进行分裂操作
            if read_node_data.children.is_none() {
                drop(read_node_data);
                self.split();
            }
            let write_node_data = self.data.write();

            // 将对象插入到合适的子节点中
            if let Some(children) = &write_node_data.children {
                for child in children.iter() {
                    if child.is_inside(&item) {
                        child.insert(item.clone());
                        return;
                    }
                }
            }
        }
    }

    pub fn remove(&self, item: &OctreeItem) -> bool {
        let node_data = self.data.read();

        // 在当前节点的对象列表中查找并删除元素
        if let Some(index) = node_data
            .objects
            .iter()
            .position(|x| Arc::ptr_eq(&x.data, &item.data))
        {
            drop(node_data);
            let mut write_data = self.data.write();
            (*write_data).objects.remove(index);
            drop(write_data);
            // 在删除元素后执行合并操作
            self.merge();
            return true;
        }

        // 如果当前节点有子节点，递归地在子节点中查找并删除元素
        if let Some(children) = &node_data.children {
            for child in children.iter() {
                if child.is_inside(item) {
                    if child.remove(item) {
                        drop(node_data);
                        // 在删除元素后执行合并操作
                        self.merge();
                        return true;
                    }
                }
            }
        }

        false
    }

    fn split(&self) {
        let mut self_data = self.data.write();

        let mut children: Vec<OctreeNode> = Vec::with_capacity(8);
        let child_half_size = [
            (*self_data).boundary.half_size[0] / 2.0,
            (*self_data).boundary.half_size[1] / 2.0,
            (*self_data).boundary.half_size[2] / 2.0,
        ];

        for i in 0..2 {
            for j in 0..2 {
                for k in 0..2 {
                    let child_center = [
                        (*self_data).boundary.center[0]
                            + (i as f32 - 0.5) * (*self_data).boundary.half_size[0],
                        (*self_data).boundary.center[1]
                            + (j as f32 - 0.5) * (*self_data).boundary.half_size[1],
                        (*self_data).boundary.center[2]
                            + (k as f32 - 0.5) * (*self_data).boundary.half_size[2],
                    ];
                    let child_boundary = BoundingBox::new(child_center, child_half_size);
                    let child_node = OctreeNode::new(
                        child_boundary,
                        (*self_data).depth + 1,
                        (*self_data).max_depth,
                        (*self_data).capacity,
                    );
                    children.push(child_node);
                }
            }
        }

        (*self_data).children = Some(
            children
                .try_into()
                .unwrap_or_else(|_v| panic!("Illegal length")),
        );

        // 将当前节点的对象移动到合适的子节点中
        for object in (*self_data).objects.iter() {
            for child in (*self_data).children.as_ref().unwrap() {
                if child.is_inside(object) {
                    child.insert(object.clone());
                    break;
                }
            }
        }

        (*self_data).objects.clear();
    }

    pub fn merge(&self) {
        let mut node_data = self.data.write();

        if let Some(children) = &mut node_data.children {
            let mut objects: Vec<OctreeItem> = Vec::new();

            // 收集所有子节点的对象
            for child in children.iter() {
                let child_data = child.data.write();
                let child_objects = child_data.objects.clone();
                objects.extend(child_objects);
            }

            // 检查合并条件是否满足：所有子节点的对象总数加上当前节点的对象数不超过容量限制
            if objects.len() + node_data.objects.len() <= node_data.capacity {
                // 将子节点的对象添加到当前节点
                node_data.objects.extend(objects);

                // 移除子节点
                node_data.children = None;
            }
        }
    }

    fn is_inside(&self, item: &OctreeItem) -> bool {
        let node_data = self.data.read();
        node_data.boundary.contains_object(item)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::octree_item::OctreeItemData;

    #[test]
    fn test_contain() {
        let boundary = BoundingBox::new([0.0, 0.0, 0.0], [10.0, 10.0, 10.0]);
        let octree = OctreeNode::new(boundary, 0, 3, 1);
        let item = OctreeItem {
            data: Arc::new(RwLock::new(OctreeItemData {
                id: 1,
                pos: [1.0, 1.0, 1.0],
            })),
        };
        assert!(octree.is_inside(&item));
    }

    #[test]
    fn test_insert() {
        let boundary = BoundingBox::new([0.0, 0.0, 0.0], [10.0, 10.0, 10.0]);
        let octree = OctreeNode::new(boundary, 0, 3, 1);
        let item = OctreeItem {
            data: Arc::new(RwLock::new(OctreeItemData {
                id: 1,
                pos: [1.0, 1.0, 1.0],
            })),
        };
        octree.insert(item.clone());
        // print!("{:#?}", octree);

        let item2 = OctreeItem {
            data: Arc::new(RwLock::new(OctreeItemData {
                id: 2,
                pos: [-1.0, 1.0, -1.0],
            })),
        };
        octree.insert(item2.clone());
        print!("objects: {:#?}", octree);

        let node_data = octree.data.read();
        assert_eq!(node_data.children.is_some(), true);
    }

    #[test]
    fn test_remove() {
        let boundary = BoundingBox {
            center: [0.0, 0.0, 0.0],
            half_size: [1.0, 1.0, 1.0],
        };
        let max_depth = 3;
        let capacity = 1;
        let root_node = OctreeNode::new(boundary, 0, max_depth, capacity);

        let item1 = OctreeItem {
            data: Arc::new(RwLock::new(OctreeItemData {
                id: 1,
                pos: [-0.5, -0.5, -0.5],
            })),
        };

        let item2 = OctreeItem {
            data: Arc::new(RwLock::new(OctreeItemData {
                id: 2,
                pos: [0.5, 0.5, 0.5],
            })),
        };

        // 插入两个对象
        root_node.insert(item1.clone());
        root_node.insert(item2.clone());

        // 移除一个对象
        assert_eq!(root_node.remove(&item1), true);

        // 检查对象是否从八叉树中删除
        let root_data = root_node.data.read();
        assert!(root_data
            .objects
            .iter()
            .find(|x| Arc::ptr_eq(&x.data, &item1.data))
            .is_none());

        // 再次尝试删除同一个对象，此时应该返回false
        assert_eq!(root_node.remove(&item1), false);
    }
}
