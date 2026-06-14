use std::time::{SystemTime, UNIX_EPOCH};

use rustler::NifStruct;

use crate::physics::physics_system::PhySys;

use super::{types::Vector, physics_comp::PhysicsComp};

/// 当前墙钟毫秒。**不 panic**(梯队2 step2.5a,NIF-6/11/15):时钟回退到 UNIX_EPOCH 之前时
/// `duration_since` 返回 Err,此处退化为 0 而非 `.unwrap()` 触发 panic 越过 FFI 边界。
fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[derive(Clone)]
pub struct Movement {
    physics_component: PhysicsComp,
    // pub location: Vector,
    pub velocity: Vector,
    pub acceleration: Vector,
    pub timestamp: u64,
    pub is_in_air: bool,
}

impl Movement {
    pub fn new(location: Vector, velocity: Vector, acceleration: Vector, physys: &mut PhySys) -> Movement {
        let timestamp = now_millis();
        let physics_component = PhysicsComp::new(location, physys);

        Movement {
            physics_component,
            velocity,
            acceleration,
            timestamp,
            is_in_air: false
        }
    }

    pub fn make_move(&mut self, physys: &mut PhySys) -> Option<Vector> {
        let new_timestamp = now_millis();

        if self.velocity
            != (Vector {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            })
        {
            let time = (new_timestamp - self.timestamp) as f64 / 1000.0;
            // println!("时间：{:#?}\n", time);
            let desired_transition = Vector{
                x: self.velocity.x * time,
                y: self.velocity.y * time,
                z: self.velocity.z * time,
            };
            // self.location.x += self.velocity.x * time;
            // self.location.y += self.velocity.y * time;
            // self.location.z += self.velocity.z * time;

            let target_location = self.physics_component.controller_move(desired_transition, physys);

            self.timestamp = new_timestamp;

            return Some(target_location);
        } else {
            self.timestamp = new_timestamp;

            return None;
        }
    }

    pub fn update(&mut self, location: Vector, velocity: Vector, acceleration: Vector, physys: &mut PhySys) {
        let new_timestamp = now_millis();


        let old_location = self.physics_component.get_location(&physys);
        let translation = location - old_location;
        // self.location = location;
        self.physics_component.controller_move(translation, physys);
        self.velocity = velocity;
        self.acceleration = acceleration;
        self.timestamp = new_timestamp;
    }

    pub fn get_location(&self, physys: &PhySys) -> Vector {
        self.physics_component.get_location(physys)
    }
}


#[derive(NifStruct, Debug, Clone)]
#[module = "MovementDebug"]
pub struct MovementDebug {
    pub location: Vector,
    pub velocity: Vector,
    pub acceleration: Vector,
    pub timestamp: u64,
    pub is_in_air: bool,
}

impl MovementDebug {
    pub fn new(movement: &Movement, physys: &PhySys) -> MovementDebug {
        MovementDebug {
            location: movement.get_location(&physys),
            velocity: movement.velocity,
            acceleration: movement.acceleration,
            timestamp: movement.timestamp,
            is_in_air: movement.is_in_air,
        }
    }
}