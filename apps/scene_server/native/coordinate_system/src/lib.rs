use std::sync::Mutex;

use bucket::Bucket;
use coordinate_system::CoordinateSystem;
use jemallocator::Jemalloc;
use rayon::prelude::{IntoParallelRefIterator, ParallelIterator};
use rustler::{Atom, Env, ResourceArc, Term};

use item::{CoordTuple, Item, OrderAxis};
use sorted_set::SortedSet;

use crate::configuration::Configuration;

mod bucket;
mod configuration;
mod coordinate_system;
mod item;
mod sorted_set;

pub struct ItemResource(Mutex<Item>);
pub type ItemArc = ResourceArc<ItemResource>;

pub struct BucketResource(Mutex<Bucket>);
pub type BucketArc = ResourceArc<BucketResource>;

pub struct SortedSetResource(Mutex<SortedSet>);
pub type SortedSetArc = ResourceArc<SortedSetResource>;

pub struct CoordinateSystemResource(Mutex<CoordinateSystem>);
pub type CoordinateSystemArc = ResourceArc<CoordinateSystemResource>;

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

#[global_allocator]
static GLOBAL_ALLOCATOR: Jemalloc = Jemalloc;

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

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(ItemResource, env);
    rustler::resource!(BucketResource, env);
    rustler::resource!(SortedSetResource, env);
    rustler::resource!(CoordinateSystemResource, env);
    true
}

rustler::init!(
    "Elixir.SceneServer.Native.CoordinateSystem",
    [
        new_item,
        get_item_raw,
        new_bucket,
        add_item_to_bucket,
        get_bucket_raw,
        new_set,
        add_item_to_set,
        get_set_raw,
        new_system,
        add_item_to_system,
        remove_item_from_system,
        update_item_from_system,
        // update_item_from_system_new,
        get_items_within_distance_from_system,
        get_system_raw,
    ],
    load = load
);

#[rustler::nif]
fn new_item(cid: i64, coord: CoordTuple) -> (Atom, ItemArc) {
    let new_item: ItemArc = ResourceArc::new(ItemResource(Mutex::new(Item::new_item(
        cid,
        coord,
        OrderAxis::X,
    ))));
    (atoms::ok(), new_item)
}

#[rustler::nif]
fn update_item_coord(itref: ResourceArc<ItemResource>, coord: CoordTuple) -> Result<Atom, Atom> {
    let mut it = match itref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };
    it.update_coord(coord);
    Ok(atoms::ok())
}

#[rustler::nif]
fn get_item_raw(itref: ResourceArc<ItemResource>) -> Result<Item, Atom> {
    let it = match itref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(it.clone())
}

#[rustler::nif]
fn new_bucket() -> (Atom, BucketArc) {
    let new_bucket = ResourceArc::new(BucketResource(Mutex::new(Bucket {
        data: Vec::with_capacity(500),
    })));
    (atoms::ok(), new_bucket)
}

#[rustler::nif]
fn add_item_to_bucket(
    bkref: ResourceArc<BucketResource>,
    cid: i64,
    coord: CoordTuple,
) -> Result<Atom, Atom> {
    let mut bk = match bkref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };
    let it = Item::new_item(cid, coord, OrderAxis::Z);
    bk.add(it);

    Ok(atoms::ok())
}

#[rustler::nif]
fn get_bucket_raw(bkref: ResourceArc<BucketResource>) -> Result<Bucket, Atom> {
    let bk = match bkref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(bk.clone())
}

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

#[rustler::nif]
fn add_item_to_set(
    ssref: ResourceArc<SortedSetResource>,
    cid: i64,
    coord: CoordTuple,
) -> Result<Atom, Atom> {
    let mut ss = match ssref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };
    let it = Item::new_item(cid, coord, OrderAxis::Z);
    ss.add(it);

    Ok(atoms::ok())
}

#[rustler::nif]
fn get_set_raw(ssref: ResourceArc<SortedSetResource>) -> Result<SortedSet, Atom> {
    // OwnedEnv::send_and_clear(&mut self, recipient, closure)
    let ss = match ssref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(ss.clone())
}

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

#[rustler::nif]
fn add_item_to_system(
    csref: ResourceArc<CoordinateSystemResource>,
    cid: i64,
    coord: CoordTuple,
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

#[rustler::nif]
fn update_item_from_system(
    csref: ResourceArc<CoordinateSystemResource>,
    itemref: ResourceArc<ItemResource>,
    new_position: CoordTuple,
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
//     new_position: CoordTuple,
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

#[rustler::nif]
fn get_items_within_distance_from_system(
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

    Ok(items.par_iter().map(|it| it.cid).collect())
}

#[rustler::nif]
fn get_system_raw(csref: ResourceArc<CoordinateSystemResource>) -> Result<CoordinateSystem, Atom> {
    let resource = &*csref;
    // OwnedEnv::send_and_clear(&mut self, recipient, closure)
    let cs = match resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(cs.clone())
}
