use bounding_box::BoundingBox;
use rustler::{Env, ResourceArc, Term};
use types::Vector3;

use crate::{debug_types::octree_debug::OctreeDebug, octree::Octree, octree_item::OctreeItem};

pub mod bounding_box;
pub mod debug_types;
pub mod octree;
pub mod octree_item;
pub mod octree_node;
pub mod types;

pub type OctreeArc = ResourceArc<Octree>;
pub type OctreeItemArc = ResourceArc<OctreeItem>;

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(Octree, env);
    rustler::resource!(OctreeItem, env);
    true
}

rustler::init!(
    "Elixir.SceneServer.Native.Octree",
    [new_tree, new_item, add_item, get_tree_raw,],
    load = load
);

// #[rustler::nif]
// fn add(a: i64, b: i64) -> i64 {
//     a + b
// }

#[rustler::nif]
fn new_tree(center: Vector3, half_size: Vector3) -> OctreeArc {
    let bounds = BoundingBox::new(center.to_arr(), half_size.to_arr());
    let octree = Octree::new(bounds, 0, 8, 8);
    ResourceArc::new(octree)
}

#[rustler::nif]
fn new_item(cid: i64, pos: Vector3) -> OctreeItemArc {
    let item = OctreeItem::new(cid, pos.to_arr());
    ResourceArc::new(item)
}

#[rustler::nif]
fn add_item(tree: OctreeArc, item: OctreeItemArc) {
    (*tree).insert((*item).clone());
}

#[rustler::nif]
fn get_tree_raw(tree: OctreeArc) -> OctreeDebug {
    OctreeDebug::new((*tree).clone())
}
