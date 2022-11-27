use std::time::{SystemTime, UNIX_EPOCH};

use rustler::NifStruct;

use super::types::Vector;

#[derive(NifStruct, Clone)]
#[module = "Movement"]
pub struct Movement {
    pub location: Vector,
    pub velocity: Vector,
    pub acceleration: Vector,
    pub timestamp: u64,
    pub is_in_air: bool,
}

impl Movement {
    pub fn new(location: Vector, velocity: Vector, acceleration: Vector) -> Movement {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;

        Movement {
            location,
            velocity,
            acceleration,
            timestamp,
            is_in_air: false
        }
    }

    pub fn make_move(&mut self) -> Option<Vector> {
        let new_timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;

        if self.velocity
            != (Vector {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            })
        {
            let time = (new_timestamp - self.timestamp) as f64 / 1000.0;
            // println!("时间：{:#?}\n", time);
            self.location.x += self.velocity.x * time;
            self.location.y += self.velocity.y * time;
            self.location.z += self.velocity.z * time;

            self.timestamp = new_timestamp;

            return Some(self.location);
        } else {
            self.timestamp = new_timestamp;

            return None;
        }
    }

    pub fn update(&mut self, location: Vector, velocity: Vector, acceleration: Vector) {
        let new_timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;

        self.location = location;
        self.velocity = velocity;
        self.acceleration = acceleration;
        self.timestamp = new_timestamp;
    }

    pub fn get_location(&self) -> Vector {
        self.location
    }
}
