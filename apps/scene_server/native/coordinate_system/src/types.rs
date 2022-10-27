use rustler::{NifTuple, NifUnitEnum};

#[derive(NifTuple, Clone, Debug, Copy, PartialEq)]
pub struct Vector {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}



#[derive(NifUnitEnum, Clone, Debug, Copy)]
pub enum OrderAxis {
    X,
    Y,
    Z,
}

impl OrderAxis {
    pub fn axis_by_index(idx: usize) -> OrderAxis {
        match idx {
            0 => OrderAxis::X,
            1 => OrderAxis::Y,
            _ => OrderAxis::Z,
        }
    }
}