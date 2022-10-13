use std::sync::Mutex;

use bucket::Bucket;
use rustler::{Atom, Env, ResourceArc, Term};

use item::{CoordTuple, Item};
use rustler::LocalPid;

mod bucket;
mod item;
mod sorted_set;

pub struct ItemResource(Mutex<Item>);
pub type ItemArc = ResourceArc<ItemResource>;

pub struct BucketResource(Mutex<Bucket>);
pub type BucketArc = ResourceArc<BucketResource>;

#[derive(Debug, PartialEq)]
pub enum AddResult {
    Added(usize),
    Duplicate(usize),
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

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(ItemResource, env);
    rustler::resource!(BucketResource, env);
    true
}

rustler::init!(
    "Elixir.SceneServer.Native.SortedSet",
    [add, new_item, get_item_raw, new_bucket, add_item_to_bucket, get_bucket_raw],
    load = load
);

#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

#[rustler::nif]
fn new_item(cid: i64, pid: LocalPid, coord: CoordTuple) -> (Atom, ItemArc) {
    let new_item: ItemArc = ResourceArc::new(ItemResource(Mutex::new(item::new_item(
        cid,
        pid,
        coord,
        item::OrderType::X,
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
    let new_bucket = ResourceArc::new(BucketResource(Mutex::new(Bucket { data: vec![] })));
    (atoms::ok(), new_bucket)
}

#[rustler::nif]
fn add_item_to_bucket(bkref: ResourceArc<BucketResource>, cid: i64, pid: LocalPid, coord: CoordTuple) -> Result<Atom, Atom> {
    let mut bk = match bkref.0.try_lock() {
        Err(_) => return Err(atoms::lock_fail()),
        Ok(guard) => guard,
    };
    let it = item::new_item(cid, pid, coord, item::OrderType::Z);
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
