pub mod character;
pub mod physics;

use std::{collections::HashMap, sync::Mutex};

use physics::physics_system::PhySys;
use rustler::{Atom, ResourceArc};

use character::character_data::CharacterData;
use character::types;

use crate::character::character_data::CharacterDataDebug;
use crate::character::types::Vector;

pub struct CharacterDataResource(Mutex<CharacterData>);
pub type CharacterDataArc = ResourceArc<CharacterDataResource>;

pub struct PhySysResource(Mutex<PhySys>);
pub type PhySysArc = ResourceArc<PhySysResource>;

#[rustler::resource_impl]
impl rustler::Resource for CharacterDataResource {}

#[rustler::resource_impl]
impl rustler::Resource for PhySysResource {}

rustler::init!("Elixir.SceneServer.Native.SceneOps");

// 调度约定(scene-rust-1):凡是触碰 rapier3d 物理管线(collider 插入、
// move_shape 形状投射、broad/narrow phase 查询)的 NIF 单次耗时可能 >1ms,
// 必须标 `schedule = "DirtyCpu"`,避免阻塞 BEAM 普通调度器线程、破坏软实时性。
// 纯 getter / 一次性构造(无计算)保留普通 NIF,避免 dirty 调度切换开销。

// new_character_data:向 rapier ColliderSet 插入 capsule collider(分配 + 注册),
// 并持有 PhySys 锁,属于会改动物理世界状态的重路径 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn new_character_data(
    cid: u64,
    nickname: String,
    location: Vector,
    dev_attrs: HashMap<String, i32>,
    physys_ref: PhySysArc,
) -> Result<CharacterDataArc, Atom> {
    let mut physys = match physys_ref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let cd = match CharacterData::new_data(cid, nickname, location, dev_attrs, &mut physys) {
        Ok(cd) => cd,
        Err(_) => return Err(types::atoms::missing_dev_attr()),
    };
    let cd_arc = ResourceArc::new(CharacterDataResource(Mutex::new(cd)));

    Ok(cd_arc)
}

// get_character_data_raw:仅读取 collider 位置并拼装 debug 结构,轻量 getter → 保留普通 NIF。
#[rustler::nif]
fn get_character_data_raw(
    cdref: CharacterDataArc,
    physys_ref: PhySysArc,
) -> Result<CharacterDataDebug, Atom> {
    let physys = match physys_ref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let cd = match cdref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(CharacterDataDebug::new(&cd, &physys))
}

// movement_tick:调用 controller_move → KinematicCharacterController::move_shape,
// 涉及形状投射 + broad/narrow phase 查询,CPU-bound 重路径 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn movement_tick(cdref: CharacterDataArc, physys_ref: PhySysArc) -> Result<Option<Vector>, Atom> {
    let mut physys = match physys_ref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let mut cd = match cdref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(cd.movement_tick(&mut physys))
}

// update_character_movement:同样调用 controller_move → move_shape 做形状投射,重路径 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn update_character_movement(
    cdref: CharacterDataArc,
    location: Vector,
    velocity: Vector,
    acceleration: Vector,
    physys_ref: PhySysArc,
) -> Result<Atom, Atom> {
    let mut physys = match physys_ref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let mut cd = match cdref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    cd.update_movement(location, velocity, acceleration, &mut physys);

    Ok(types::atoms::ok())
}

// get_character_location:仅读取 collider 平移分量,纯 getter → 保留普通 NIF。
#[rustler::nif]
fn get_character_location(cdref: CharacterDataArc, physys_ref: PhySysArc) -> Result<Vector, Atom> {
    let physys = match physys_ref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    let cd = match cdref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(cd.get_location(&physys))
}

// new_physics_system:仅构造空的 rapier 管线(无模拟计算),每个场景仅调用一次,
// 属于一次性轻量构造 → 保留普通 NIF。
#[rustler::nif]
fn new_physics_system() -> Result<PhySysArc, Atom> {
    let physys = PhySys::new();
    let physys_arc = ResourceArc::new(PhySysResource(Mutex::new(physys)));

    Ok(physys_arc)
}