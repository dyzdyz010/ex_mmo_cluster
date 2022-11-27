use std::collections::HashMap;

use rustler::NifStruct;

use super::movement::Movement;
use super::dev_attrs::DevAttrs;
use super::types::Vector;

#[derive(NifStruct, Clone)]
#[module = "CharacterData"]
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
    ) -> CharacterData {
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
        );
        let dev_attrs_comp = DevAttrs::new(
            dev_attrs.get("mmr").unwrap().to_owned(),
            dev_attrs.get("cph").unwrap().to_owned(),
            dev_attrs.get("cct").unwrap().to_owned(),
            dev_attrs.get("pct").unwrap().to_owned(),
            dev_attrs.get("rsl").unwrap().to_owned(),
        );

        CharacterData { cid, nickname, movement: move_comp, dev_attrs: dev_attrs_comp }
    }

    pub fn movement_tick(&mut self) -> Option<Vector> {
        self.movement.make_move()
    }

    pub fn update_movement(&mut self, location: Vector, velocity: Vector, acceleration: Vector) {
        self.movement.update(location, velocity, acceleration);
    }

    pub fn get_location(&self) -> Vector {
        self.movement.get_location()
    }
}
