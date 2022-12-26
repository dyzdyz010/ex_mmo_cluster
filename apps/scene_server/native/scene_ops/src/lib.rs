pub mod character;
pub mod physics;

use std::{collections::HashMap, sync::Mutex};

use physics::physics_system::PhySys;
use rustler::{Atom, Env, ResourceArc, Term};

use character::character_data::CharacterData;
use character::types;

use crate::character::character_data::CharacterDataDebug;
use crate::character::types::Vector;

pub struct CharacterDataResource(Mutex<CharacterData>);
pub type CharacterDataArc = ResourceArc<CharacterDataResource>;

pub struct PhySysResource(Mutex<PhySys>);
pub type PhySysArc = ResourceArc<PhySysResource>;

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(CharacterDataResource, env);
    rustler::resource!(PhySysResource, env);
    true
}

rustler::init!(
    "Elixir.SceneServer.Native.SceneOps",
    [
        new_character_data,
        get_character_data_raw,
        movement_tick,
        update_character_movement,
        get_character_location,
        new_physics_system,
    ],
    load = load
);

#[rustler::nif]
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

    let cd = CharacterData::new_data(cid, nickname, location, dev_attrs, &mut physys);
    let cd_arc = ResourceArc::new(CharacterDataResource(Mutex::new(cd)));

    Ok(cd_arc)
}

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

#[rustler::nif]
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

#[rustler::nif]
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

#[rustler::nif]
fn new_physics_system() -> Result<PhySysArc, Atom> {
    let physys = PhySys::new();
    let physys_arc = ResourceArc::new(PhySysResource(Mutex::new(physys)));

    Ok(physys_arc)
}