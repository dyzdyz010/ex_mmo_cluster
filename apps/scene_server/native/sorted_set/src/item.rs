use std::cmp::Ordering;

use rustler::{LocalPid, NifTuple, NifStruct, NifUnitEnum};

#[derive(NifUnitEnum, Clone)]
pub enum OrderType {
    X,
    Y,
    Z,
}

#[derive(NifTuple, Clone)]
#[derive(Debug)]
pub struct CoordTuple {
    x: f64,
    y: f64,
    z: f64,
}

#[derive(NifStruct, Clone)]
#[module = "Item"]
pub struct Item {
    pub cid: i64,
    pid: LocalPid,
    coord: CoordTuple,
    order_type: OrderType,
}

pub fn new_item(cid: i64, pid: LocalPid, coord: CoordTuple, order_type: OrderType) -> Item {
    Item{cid, pid, coord, order_type}
}

impl Item {
    pub fn update_coord(&mut self, coord: CoordTuple) {
        self.coord = coord;

    }
}

impl PartialEq for Item {
    fn eq(&self, other: &Self) -> bool {
        match self.order_type {
            OrderType::X => self.coord.x.eq(&other.coord.x),
            OrderType::Y => self.coord.y.eq(&other.coord.y),
            OrderType::Z => self.coord.z.eq(&other.coord.z),
        }
    }
}

impl PartialOrd for Item {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        match self.order_type {
            OrderType::X => self.coord.x.partial_cmp(&other.coord.x),
            OrderType::Y => self.coord.y.partial_cmp(&other.coord.y),
            OrderType::Z => self.coord.z.partial_cmp(&other.coord.z),
        }
    }
}

impl Eq for Item {}

impl Ord for Item {
    fn cmp(&self, other: &Self) -> Ordering {
        match self.order_type {
            OrderType::X => self.coord.x.partial_cmp(&other.coord.x).unwrap(),
            OrderType::Y => self.coord.y.partial_cmp(&other.coord.y).unwrap(),
            OrderType::Z => self.coord.z.partial_cmp(&other.coord.z).unwrap(),
        }
    }
}

// impl ResourceTypeProvider for ItemResource {
//     fn get_type() -> &'static rustler::resource::ResourceType<Self> {
        
//     }
// }