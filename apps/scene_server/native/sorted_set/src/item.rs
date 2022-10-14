use std::cmp::Ordering;

use rustler::{NifStruct, NifTuple, NifUnitEnum};

#[derive(NifUnitEnum, Clone, Debug)]
pub enum OrderAxis {
    X,
    Y,
    Z,
}

#[derive(NifTuple, Clone, Debug)]
pub struct CoordTuple {
    x: f64,
    y: f64,
    z: f64,
}

#[derive(NifStruct, Clone, Debug)]
#[module = "Item"]
pub struct Item {
    pub cid: i64,
    coord: CoordTuple,
    order_type: OrderAxis,
}

impl Item {
    pub fn new_item(cid: i64, coord: CoordTuple, order_type: OrderAxis) -> Item {
        Item {
            cid,
            coord,
            order_type,
        }
    }

    pub fn update_coord(&mut self, coord: CoordTuple) {
        self.coord = coord;
    }
}

impl PartialEq for Item {
    fn eq(&self, other: &Self) -> bool {
        match self.order_type {
            OrderAxis::X => self.coord.x.eq(&other.coord.x),
            OrderAxis::Y => self.coord.y.eq(&other.coord.y),
            OrderAxis::Z => self.coord.z.eq(&other.coord.z),
        }
    }
}

impl PartialOrd for Item {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        match self.order_type {
            OrderAxis::X => self.coord.x.partial_cmp(&other.coord.x),
            OrderAxis::Y => self.coord.y.partial_cmp(&other.coord.y),
            OrderAxis::Z => self.coord.z.partial_cmp(&other.coord.z),
        }
    }
}

impl Eq for Item {}

impl Ord for Item {
    fn cmp(&self, other: &Self) -> Ordering {
        match self.order_type {
            OrderAxis::X => self.coord.x.partial_cmp(&other.coord.x).unwrap(),
            OrderAxis::Y => self.coord.y.partial_cmp(&other.coord.y).unwrap(),
            OrderAxis::Z => self.coord.z.partial_cmp(&other.coord.z).unwrap(),
        }
    }
}

// impl ResourceTypeProvider for ItemResource {
//     fn get_type() -> &'static rustler::resource::ResourceType<Self> {

//     }
// }
