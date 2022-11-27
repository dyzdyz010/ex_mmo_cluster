pub mod character;
pub mod physics;

use std::{collections::HashMap, sync::Mutex};

use rustler::{Atom, Env, ResourceArc, Term};

use character::character_data::CharacterData;
use character::types;

use crate::character::types::Vector;

pub struct CharacterDataResource(Mutex<CharacterData>);
pub type CharacterDataArc = ResourceArc<CharacterDataResource>;

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(CharacterDataResource, env);
    true
}

rustler::init!(
    "Elixir.SceneServer.Native.SceneOps",
    [
        new_character_data,
        get_character_data_raw,
        movement_tick,
        update_character_movement,
        get_character_location
    ],
    load = load
);

#[rustler::nif]
fn new_character_data(
    cid: u64,
    nickname: String,
    location: Vector,
    dev_attrs: HashMap<String, i32>,
) -> Result<CharacterDataArc, Atom> {
    let cd = CharacterData::new_data(cid, nickname, location, dev_attrs);
    let cd_arc = ResourceArc::new(CharacterDataResource(Mutex::new(cd)));

    Ok(cd_arc)
}

#[rustler::nif]
fn get_character_data_raw(cdref: CharacterDataArc) -> Result<CharacterData, Atom> {
    let cd = match cdref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(cd.clone())
}

#[rustler::nif]
fn movement_tick(cdref: CharacterDataArc) -> Result<Option<Vector>, Atom> {
    let mut cd = match cdref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(cd.movement_tick())
}

#[rustler::nif]
fn update_character_movement(
    cdref: CharacterDataArc,
    location: Vector,
    velocity: Vector,
    acceleration: Vector,
) -> Result<Atom, Atom> {
    let mut cd = match cdref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    cd.update_movement(location, velocity, acceleration);

    Ok(types::atoms::ok())
}

#[rustler::nif]
fn get_character_location(cdref: CharacterDataArc) -> Result<Vector, Atom> {
    let cd = match cdref.0.try_lock() {
        Err(_) => return Err(types::atoms::lock_fail()),
        Ok(guard) => guard,
    };

    Ok(cd.get_location())
}
