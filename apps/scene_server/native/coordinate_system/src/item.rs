use std::cmp::Ordering;

use rustler::{NifStruct, NifTuple, NifUnitEnum};

#[derive(NifUnitEnum, Clone, Debug)]
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

#[derive(NifTuple, Clone, Debug)]
pub struct CoordTuple {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

#[derive(NifStruct, Clone, Debug)]
#[module = "Item"]
pub struct Item {
    pub cid: i64,
    pub coord: CoordTuple,
    pub order_type: OrderAxis,
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

#[cfg(test)]
mod tests {
    use crate::item::{CoordTuple, OrderAxis};

    use super::*;
    use std::cmp::Ordering;

    #[test]
    fn test_item_compare_when_equal() {
        let item1 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );
        let item2 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 3.0,
                z: 5.0,
            },
            OrderAxis::X,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Equal);

        let item1 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );
        let item2 = Item::new_item(
            1,
            CoordTuple {
                x: 4.0,
                y: 2.0,
                z: 5.0,
            },
            OrderAxis::Y,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Equal);

        let item1 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 5.0,
            },
            OrderAxis::Z,
        );
        let item2 = Item::new_item(
            1,
            CoordTuple {
                x: 3.0,
                y: 4.0,
                z: 5.0,
            },
            OrderAxis::Z,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Equal);
    }

    #[test]
    fn test_item_compare_when_less_than() {
        let item1 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );
        let item2 = Item::new_item(
            1,
            CoordTuple {
                x: 2.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Less);

        let item1 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );
        let item2 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 3.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Less);

        let item1 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 3.0,
                z: 4.0,
            },
            OrderAxis::Z,
        );
        let item2 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 3.0,
                z: 5.0,
            },
            OrderAxis::Z,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Less);
    }

    #[test]
    fn test_item_compare_when_greater_than() {
        let item1 = Item::new_item(
            1,
            CoordTuple {
                x: 2.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );
        let item2 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Greater);

        let item1 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 3.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );
        let item2 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Greater);

        let item1 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 3.0,
                z: 5.0,
            },
            OrderAxis::Z,
        );
        let item2 = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 3.0,
                z: 4.0,
            },
            OrderAxis::Z,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Greater);
    }
}
