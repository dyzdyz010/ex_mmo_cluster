use std::ops::Sub;

use rustler::NifTuple;

#[derive(NifTuple, Clone, Debug, Copy, PartialEq)]
pub struct Vector {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Sub for Vector {
    type Output = Vector;

    fn sub(self, rhs: Self) -> Self::Output {
        Vector{x: self.x - rhs.x, y: self.y - rhs.y, z: self.z - rhs.z}
    }
}

pub mod atoms {
    rustler::atoms! {
        // Common Atoms
        ok,
        error,

        // Resource Atoms
        bad_reference,
        lock_fail,
    }
}