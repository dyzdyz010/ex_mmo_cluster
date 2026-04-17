use std::collections::HashMap;

use rustler::NifStruct;

use crate::physics::physics_system::PhySys;

use super::movement::{Movement, MovementDebug};
use super::dev_attrs::DevAttrs;
use super::types::Vector;

#[derive(Debug)]
pub struct MissingDevAttr(pub &'static str);

#[derive(Clone)]
pub struct CharacterData {
    pub cid: u64,
    pub nickname: String,
    pub movement: Movement,
    pub dev_attrs: DevAttrs,
}

impl CharacterData {
    pub fn new_data(
        cid: u64,
        nickname: String,
        location: Vector,
        dev_attrs: HashMap<String, i32>,
        physys: &mut PhySys
    ) -> Result<CharacterData, MissingDevAttr> {
        let move_comp = Movement::new(
            location,
            Vector {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            Vector {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            physys
        );
        let mmr = *dev_attrs.get("mmr").ok_or(MissingDevAttr("mmr"))?;
        let cph = *dev_attrs.get("cph").ok_or(MissingDevAttr("cph"))?;
        let cct = *dev_attrs.get("cct").ok_or(MissingDevAttr("cct"))?;
        let pct = *dev_attrs.get("pct").ok_or(MissingDevAttr("pct"))?;
        let rsl = *dev_attrs.get("rsl").ok_or(MissingDevAttr("rsl"))?;
        let dev_attrs_comp = DevAttrs::new(mmr, cph, cct, pct, rsl);

        Ok(CharacterData { cid, nickname, movement: move_comp, dev_attrs: dev_attrs_comp })
    }

    pub fn movement_tick(&mut self, physys: &mut PhySys) -> Option<Vector> {
        self.movement.make_move(physys)
    }

    pub fn update_movement(&mut self, location: Vector, velocity: Vector, acceleration: Vector, physys: &mut PhySys) {
        self.movement.update(location, velocity, acceleration, physys);
    }

    pub fn get_location(&self, physys: &PhySys) -> Vector {
        self.movement.get_location(physys)
    }
}

#[derive(NifStruct, Debug, Clone)]
#[module = "CharacterDataDebug"]
pub struct CharacterDataDebug {
    pub cid: u64,
    pub nickname: String,
    pub movement: MovementDebug,
    pub dev_attrs: DevAttrs,
}

impl CharacterDataDebug {
    pub fn new(data: &CharacterData, physys: &PhySys) -> CharacterDataDebug {
        CharacterDataDebug {
            cid: data.cid,
            nickname: data.nickname.clone(),
            movement: MovementDebug::new(&data.movement, &physys),
            dev_attrs: data.dev_attrs.clone(),
        }
    }
}