use std::sync::Mutex;

use bucket::Bucket;
use coordinate_system::CoordinateSystem;
use rustler::{Atom, ResourceArc};

use item::{Item};
use sorted_set::SortedSet;
use types::Vector;

use crate::{configuration::Configuration, types::OrderAxis};

mod bucket;
mod configuration;
mod coordinate_system;
mod item;
mod sorted_set;
mod calc;
mod types;

pub struct ItemResource(Mutex<Item>);
pub type ItemArc = ResourceArc<ItemResource>;

pub struct BucketResource(Mutex<Bucket>);
pub type BucketArc = ResourceArc<BucketResource>;

pub struct SortedSetResource(Mutex<SortedSet>);
pub type SortedSetArc = ResourceArc<SortedSetResource>;

pub struct CoordinateSystemResource(Mutex<CoordinateSystem>);
pub type CoordinateSystemArc = ResourceArc<CoordinateSystemResource>;

#[rustler::resource_impl]
impl rustler::Resource for ItemResource {}

#[rustler::resource_impl]
impl rustler::Resource for BucketResource {}

#[rustler::resource_impl]
impl rustler::Resource for SortedSetResource {}

#[rustler::resource_impl]
impl rustler::Resource for CoordinateSystemResource {}

#[derive(Debug, PartialEq)]
pub enum FindResult {
    Found {
        bucket_idx: usize,
        inner_idx: usize,
        idx: usize,
    },
    NotFound,
}

#[derive(Debug, PartialEq)]
pub enum AddResult {
    Added(usize, usize, usize),
    Error((SetAddResult, SetAddResult, SetAddResult)),
}

#[derive(Debug, PartialEq)]
pub enum RemoveResult {
    Removed(usize, usize, usize),
    Error((SetRemoveResult, SetRemoveResult, SetRemoveResult)),
}

#[derive(Debug, PartialEq)]
pub enum UpdateResult {
    Updated(usize, usize, usize),
    Error,
}

#[derive(Debug, PartialEq, Copy, Clone)]
pub enum SetAddResult {
    Added(usize),
    Duplicate(usize),
}

#[derive(Debug, PartialEq, Copy, Clone)]
pub enum SetRemoveResult {
    Removed(usize),
    NotFound,
}

mod atoms {
    rustler::atoms! {
        // Common Atoms
        ok,
        error,

        // Resource Atoms
        bad_reference,
        lock_fail,

        // Success Atoms
        added,
        duplicate,
        removed,

        // Error Atoms
        unsupported_type,
        not_found,
        index_out_of_bounds,
        max_bucket_size_exceeded,
    }
}

rustler::init!("Elixir.SceneServer.Native.CoordinateSystem");

// 调度约定(scene-rust-1):
// 该 crate 是旧坐标系实现(逐步被 octree 取代)。重路径只有两类:
//   1) 范围/距离查询(items_within_distance_for_item):扫描整个轴上的桶 → DirtyCpu;
//   2) 整结构深克隆的 *_raw debug dump(SortedSet / CoordinateSystem 全量) → DirtyCpu。
// 其余都是单实体的构造 / 有界 sorted 插入删除 / 纯算术,保留普通 NIF,避免 dirty
// 调度切换开销。本 crate 已移除 rayon(见各处注释):dirty 线程上再开 rayon 池是反模式,
// 且这里的并行维度(3 条轴 / 少量桶)收益不抵开销。

// new_item:构造单个 Item,轻量 → 普通 NIF。
#[rustler::nif]
fn new_item(cid: i64, coord: Vector) -> (Atom, ItemArc) {
    let new_item: ItemArc = ResourceArc::new(ItemResource(Mutex::new(Item::new_item(
        cid,
        coord,
        OrderAxis::X,
    ))));
    (atoms::ok(), new_item)
}

// update_item_coord:更新单个 item 的坐标,纯写入 → 普通 NIF。
#[rustler::nif]
fn update_item_coord(itref: ResourceArc<ItemResource>, coord: Vector) -> Result<Atom, Atom> {
    let mut it = match itref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };
    it.update_coord(coord);
    Ok(atoms::ok())
}

// get_item_raw:克隆单个 item,轻量 → 普通 NIF。
#[rustler::nif]
fn get_item_raw(itref: ResourceArc<ItemResource>) -> Result<Item, Atom> {
    let it = match itref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(it.clone())
}

// new_bucket:构造空 bucket,轻量 → 普通 NIF。
#[rustler::nif]
fn new_bucket() -> (Atom, BucketArc) {
    let new_bucket = ResourceArc::new(BucketResource(Mutex::new(Bucket {
        data: Vec::with_capacity(500),
    })));
    (atoms::ok(), new_bucket)
}

// add_item_to_bucket:向单个 bucket 做一次有界 sorted 插入(桶容量上限固定),轻量 → 普通 NIF。
#[rustler::nif]
fn add_item_to_bucket(
    bkref: ResourceArc<BucketResource>,
    cid: i64,
    coord: Vector,
) -> Result<Atom, Atom> {
    let mut bk = match bkref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };
    let it = Item::new_item(cid, coord, OrderAxis::Z);
    bk.add(it);

    Ok(atoms::ok())
}

// get_bucket_raw:克隆单个 bucket(容量有界),轻量 → 普通 NIF。
#[rustler::nif]
fn get_bucket_raw(bkref: ResourceArc<BucketResource>) -> Result<Bucket, Atom> {
    let bk = match bkref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(bk.clone())
}

// new_set:构造空 SortedSet,轻量 → 普通 NIF。
#[rustler::nif]
fn new_set(set_capacity: usize, bucket_capacity: usize) -> (Atom, SortedSetArc) {
    let initial_set_capacity: usize = (set_capacity / bucket_capacity) + 1;

    let configuration = Configuration {
        bucket_capacity: bucket_capacity,
        set_capacity: initial_set_capacity,
    };

    let resource = ResourceArc::new(SortedSetResource(Mutex::new(SortedSet::new(configuration))));

    (atoms::ok(), resource)
}

// add_item_to_set:一次 sorted-set 插入(二分定位 + 桶内有界 shift),轻量 → 普通 NIF。
#[rustler::nif]
fn add_item_to_set(
    ssref: ResourceArc<SortedSetResource>,
    cid: i64,
    coord: Vector,
) -> Result<Atom, Atom> {
    let mut ss = match ssref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };
    let it = Item::new_item(cid, coord, OrderAxis::Z);
    ss.add(it);

    Ok(atoms::ok())
}

// get_set_raw:深克隆整个 SortedSet(可含全量元素)用于 debug dump,O(N) → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn get_set_raw(ssref: ResourceArc<SortedSetResource>) -> Result<SortedSet, Atom> {
    // OwnedEnv::send_and_clear(&mut self, recipient, closure)
    let ss = match ssref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(ss.clone())
}

// new_system:构造空 CoordinateSystem(3 个空 SortedSet),轻量 → 普通 NIF。
#[rustler::nif]
fn new_system(set_capacity: usize, bucket_capacity: usize) -> (Atom, CoordinateSystemArc) {
    let initial_set_capacity: usize = (set_capacity / bucket_capacity) + 1;

    let configuration = Configuration {
        bucket_capacity,
        set_capacity: initial_set_capacity,
    };

    let resource = ResourceArc::new(CoordinateSystemResource(Mutex::new(CoordinateSystem::new(
        configuration,
    ))));

    (atoms::ok(), resource)
}

// add_item_to_system:对 3 条轴各做一次有界 sorted 插入(单实体),不扫描全量 → 普通 NIF。
#[rustler::nif]
fn add_item_to_system(
    csref: ResourceArc<CoordinateSystemResource>,
    cid: i64,
    coord: Vector,
) -> Result<ItemArc, Atom> {
    let resource: &CoordinateSystemResource = &*csref;
    // data.
    let mut cs = match resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };
    let it = Item::new_item(cid, coord, OrderAxis::Z);

    match cs.add(&it) {
        AddResult::Added(_, _, _) => Ok(ResourceArc::new(ItemResource(Mutex::new(it)))),
        _ => Err(atoms::duplicate()),
    }

    // println!("Nif call.");

    // Ok(ResourceArc::new(ItemResource(Mutex::new(it))))
}

// remove_item_from_system:对 3 条轴各做一次有界删除(单实体) → 普通 NIF。
#[rustler::nif]
fn remove_item_from_system(
    csref: ResourceArc<CoordinateSystemResource>,
    itemref: ResourceArc<ItemResource>,
) -> Result<(usize, usize, usize), Atom> {
    let sys_resource: &CoordinateSystemResource = &*csref;
    let item_resource: &ItemResource = &*itemref;

    let mut cs = match sys_resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let mut item = match item_resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    match cs.remove(&mut item) {
        RemoveResult::Removed(idxx, idxy, idxz) => return Ok((idxx, idxy, idxz)),
        RemoveResult::Error(_) => return Err(atoms::not_found()),
    }
}

// update_item_from_system:remove+add 各 3 轴(单实体,有界) → 普通 NIF。
#[rustler::nif]
fn update_item_from_system(
    csref: ResourceArc<CoordinateSystemResource>,
    itemref: ResourceArc<ItemResource>,
    new_position: Vector,
) -> Result<(usize, usize, usize), Atom> {
    let sys_resource: &CoordinateSystemResource = &*csref;
    let item_resource: &ItemResource = &*itemref;

    let mut cs = match sys_resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let mut item = match item_resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    match cs.update(&mut item, new_position) {
        UpdateResult::Updated(idxx, idxy, idxz) => Ok((idxx, idxy, idxz)),
        UpdateResult::Error => Err(atoms::not_found()),
    }
}

// #[rustler::nif]
// fn update_item_from_system_new(
//     csref: ResourceArc<CoordinateSystemResource>,
//     itemref: ResourceArc<ItemResource>,
//     new_position: Vector,
// ) -> Result<(usize, usize, usize), Atom> {
//     let sys_resource: &CoordinateSystemResource = &*csref;
//     let item_resource: &ItemResource = &*itemref;

//     let mut cs = match sys_resource.0.try_lock() {
//         Err(_) => return Err(atoms::lock_fail()),
//         Ok(guard) => guard,
//     };

//     let mut item = match item_resource.0.try_lock() {
//         Err(_) => return Err(atoms::lock_fail()),
//         Ok(guard) => guard,
//     };

//     match cs.update_new(&mut item, new_position) {
//         UpdateResult::Updated(idxx, idxy, idxz) => Ok((idxx, idxy, idxz)),
//         UpdateResult::Error => Err(atoms::not_found()),
//     }
// }

// get_cids_within_distance_from_system:范围/距离查询,需扫描各轴上落在距离内的桶 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn get_cids_within_distance_from_system(
    csref: ResourceArc<CoordinateSystemResource>,
    itemref: ResourceArc<ItemResource>,
    distance: f64,
) -> Result<Vec<i64>, Atom> {
    let sys_resource: &CoordinateSystemResource = &*csref;
    let item_resource: &ItemResource = &*itemref;

    let cs = match sys_resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let item = match item_resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let items = cs.items_within_distance_for_item(&item, distance);

    // scene-rust-1:移除 rayon,结果集顺序映射。
    Ok(items.iter().map(|it| it.cid).collect())
}

// get_items_within_distance_from_system:同上范围查询,且返回完整 Item 集合 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn get_items_within_distance_from_system(
    csref: ResourceArc<CoordinateSystemResource>,
    itemref: ResourceArc<ItemResource>,
    distance: f64,
) -> Result<Vec<Item>, Atom> {
    let sys_resource: &CoordinateSystemResource = &*csref;
    let item_resource: &ItemResource = &*itemref;

    let cs = match sys_resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let item = match item_resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let items = cs.items_within_distance_for_item(&item, distance);

    // scene-rust-1:移除 rayon,结果集顺序映射(解两层引用得到 Item 值)。
    Ok(items.iter().map(|&&it| it).collect())
}

// get_system_raw:深克隆整个 CoordinateSystem(3 轴全量元素)用于 debug dump,O(N) → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn get_system_raw(csref: ResourceArc<CoordinateSystemResource>) -> Result<CoordinateSystem, Atom> {
    let resource = &*csref;
    // OwnedEnv::send_and_clear(&mut self, recipient, closure)
    let cs = match resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(cs.clone())
}


// calculate_coordinate:纯线性外推算术(几次乘加),亚微秒级 → 普通 NIF。
#[rustler::nif]
fn calculate_coordinate(old_timestamp: i64, new_timestamp: i64, location: Vector, velocity: Vector) -> Vector {
    let new_coord = calc::calculate_coordinate(old_timestamp, new_timestamp, location, velocity);

    return new_coord;
}