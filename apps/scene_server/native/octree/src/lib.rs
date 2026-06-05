use bounding_box::BoundingBox;
use rustler::ResourceArc;
use types::Vector3;

use crate::{debug_types::octree_debug::OctreeDebug, octree::Octree, octree_item::OctreeItem};

pub mod bounding_box;
pub mod debug_types;
pub mod octree;
pub mod octree_item;
pub mod octree_node;
pub mod types;

#[rustler::resource_impl]
impl rustler::Resource for Octree {}

#[rustler::resource_impl]
impl rustler::Resource for OctreeItem {}

pub type OctreeArc = ResourceArc<Octree>;
pub type OctreeItemArc = ResourceArc<OctreeItem>;

rustler::init!("Elixir.SceneServer.Native.Octree");

// 调度约定(scene-rust-1):凡是对八叉树做递归遍历(insert 分裂 / remove 合并 /
// 范围查询 / 全树克隆)的 NIF,单次耗时随树规模增长可能 >1ms,必须标
// `schedule = "DirtyCpu"`,避免阻塞 BEAM 普通调度器。仅构造单个节点 / 单个 item
// 的纯构造 NIF 保留普通 NIF,避免 dirty 调度切换开销。

// #[rustler::nif]
// fn add(a: i64, b: i64) -> i64 {
//     a + b
// }

// new_tree:仅构造根节点,一次性轻量构造 → 保留普通 NIF。
#[rustler::nif]
fn new_tree(center: Vector3, half_size: Vector3) -> OctreeArc {
    let bounds = BoundingBox::new(center.to_arr(), half_size.to_arr());
    let octree = Octree::new(bounds, 0, 8, 8);
    ResourceArc::new(octree)
}

// new_item:仅构造单个 OctreeItem,一次性轻量构造 → 保留普通 NIF。
#[rustler::nif]
fn new_item(cid: i64, pos: Vector3) -> OctreeItemArc {
    let item = OctreeItem::new(cid, pos.to_arr());
    ResourceArc::new(item)
}

// add_item:insert 沿八叉树递归下降,可能触发节点分裂(分配 + 对象再分配),
// 单次耗时随树规模增长 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn add_item(tree: OctreeArc, item: OctreeItemArc) {
    (*tree).insert((*item).clone());
}

// remove_item:remove 沿八叉树递归查找,删除后触发 merge 合并(遍历兄弟子节点),
// 单次耗时随树规模增长 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn remove_item(tree: OctreeArc, item: OctreeItemArc) -> bool {
    (*tree).remove(&(*item))
}

// get_in_bound:范围查询递归遍历与查询框相交的整棵子树并收集 item(AOI 热点路径),
// 单次耗时随命中规模增长 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn get_in_bound(tree: OctreeArc, center: Vector3, half_size: Vector3) -> Vec<i64> {
    let bounds = BoundingBox::new(center.to_arr(), half_size.to_arr());
    let result: Vec<OctreeItem> = (*tree).get(&bounds);
    // print!("result: {:#?}", result.len());
    result
        .into_iter()
        .map(|item| (*(item.data)).read().id)
        .collect()
}

// get_in_bound_except:同为递归范围查询(AOI 邻居查询,排除自身),重路径 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn get_in_bound_except(
    tree: OctreeArc,
    except: OctreeItemArc,
    half_size: Vector3,
) -> Vec<i64> {
    let center = (*(except.data)).read().pos;
    let bounds = BoundingBox::new(center, half_size.to_arr());
    let result = (*tree).get_except(&*except, bounds);
    result
        .into_iter()
        .map(|item| (*(item.data)).read().id)
        .collect()
}

// get_tree_raw:对整棵树做深克隆用于 debug dump,耗时随树规模线性增长 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn get_tree_raw(tree: OctreeArc) -> OctreeDebug {
    OctreeDebug::new((*tree).clone())
}
