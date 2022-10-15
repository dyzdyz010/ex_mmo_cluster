use std::{sync::Mutex};

use bucket::Bucket;
use coordinate_system::CoordinateSystem;
use jemallocator::Jemalloc;
use rustler::{Atom, Env, ResourceArc, Term, NifTuple};

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
pub enum SetAddResult {
    Added(usize),
    Duplicate(usize),
}

#[derive(Debug, PartialEq)]
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
        bucket_capacity: bucket_capacity,
        set_capacity: initial_set_capacity,
    };

    let resource = ResourceArc::new(CoordinateSystemResource(Mutex::new(CoordinateSystem::new(configuration))));

    (atoms::ok(), resource)
}

#[rustler::nif]
fn add_item_to_system(
    csref: ResourceArc<CoordinateSystemResource>,
    cid: i64,
    coord: CoordTuple,
) -> Result<Atom, Atom> {
    let resource: &CoordinateSystemResource = &*csref;
    // data.
    let mut cs = match resource.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };
    let it = Item::new_item(cid, coord, OrderAxis::Z);
    
    cs.add(&it);

    // println!("Nif call.");

    Ok(atoms::ok())
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