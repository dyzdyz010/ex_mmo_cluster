use std::{cmp::Ordering};

use rustler::NifStruct;

use crate::types::{Vector, OrderAxis};

// pub struct SetItem<'a> {
//     pub data: &'a Item,
//     pub order_type: OrderAxis,
// }

#[derive(NifStruct, Clone, Debug, Copy)]
#[module = "Item"]
pub struct Item {
    pub cid: i64,
    pub coord: Vector,
    pub order_type: OrderAxis,
}

impl Item {
    pub fn new_item(cid: i64, coord: Vector, order_type: OrderAxis) -> Item {
        Item {
            cid,
            coord,
            order_type,
        }
    }

    pub fn update_coord(&mut self, coord: Vector) {
        self.coord = coord;
    }

    #[inline(always)]
    pub fn distance(&self, other: &Item) -> f64 {
        f64::sqrt((self.coord.x - other.coord.x).powi(2) + (self.coord.y - other.coord.y).powi(2) + (self.coord.z - other.coord.z).powi(2))
    }
}

// impl PartialEq for SetItem<'_> {
//     fn eq(&self, other: &Self) -> bool {
//         self.data.eq(other.data)
//     }
// }

// impl PartialOrd for SetItem<'_> {
//     fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
//         if self.data.eq(other.data) {
//             return Some(Ordering::Equal);
//         }
//         let result = match self.order_type {
//             OrderAxis::X => self.data.coord.x.partial_cmp(&other.data.coord.x),
//             OrderAxis::Y => self.data.coord.y.partial_cmp(&other.data.coord.y),
//             OrderAxis::Z => self.data.coord.z.partial_cmp(&other.data.coord.z),
//         };

//         match result {
//             Some(Ordering::Equal) => Some(Ordering::Greater),
//             other => other
//         }
//     }
// }

impl PartialEq for Item {
    fn eq(&self, other: &Self) -> bool {
        self.cid.eq(&other.cid)
    }
}

impl PartialOrd for Item {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        if self.cid == other.cid {
            return Some(Ordering::Equal);
        }
        let result = match self.order_type {
            OrderAxis::X => self.coord.x.partial_cmp(&other.coord.x),
            OrderAxis::Y => self.coord.y.partial_cmp(&other.coord.y),
            OrderAxis::Z => self.coord.z.partial_cmp(&other.coord.z),
        };

        match result {
            Some(Ordering::Equal) => Some(Ordering::Greater),
            other => other
        }
    }
}

impl Eq for Item {}

impl Ord for Item {
    fn cmp(&self, other: &Self) -> Ordering {
        self.partial_cmp(&other).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use crate::item::{Vector, OrderAxis};

    use super::*;
    use std::cmp::Ordering;

    #[test]
    fn test_item_compare_when_equal() {
        let item1 = Item::new_item(
            1,
            Vector {
                x: 1.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );
        let item2 = Item::new_item(
            1,
            Vector {
                x: 1.0,
                y: 3.0,
                z: 5.0,
            },
            OrderAxis::X,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Equal);

        let item1 = Item::new_item(
            1,
            Vector {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );
        let item2 = Item::new_item(
            1,
            Vector {
                x: 4.0,
                y: 2.0,
                z: 5.0,
            },
            OrderAxis::Y,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Equal);

        let item1 = Item::new_item(
            1,
            Vector {
                x: 1.0,
                y: 2.0,
                z: 5.0,
            },
            OrderAxis::Z,
        );
        let item2 = Item::new_item(
            1,
            Vector {
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
            Vector {
                x: 1.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );
        let item2 = Item::new_item(
            2,
            Vector {
                x: 2.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Less);

        let item1 = Item::new_item(
            1,
            Vector {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );
        let item2 = Item::new_item(
            2,
            Vector {
                x: 1.0,
                y: 3.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Less);

        let item1 = Item::new_item(
            1,
            Vector {
                x: 1.0,
                y: 3.0,
                z: 4.0,
            },
            OrderAxis::Z,
        );
        let item2 = Item::new_item(
            2,
            Vector {
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
            Vector {
                x: 2.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );
        let item2 = Item::new_item(
            2,
            Vector {
                x: 1.0,
                y: 2.0,
                z: 4.0,
            },
            OrderAxis::X,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Greater);

        let item1 = Item::new_item(
            1,
            Vector {
                x: 1.0,
                y: 3.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );
        let item2 = Item::new_item(
            2,
            Vector {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::Y,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Greater);

        let item1 = Item::new_item(
            1,
            Vector {
                x: 1.0,
                y: 3.0,
                z: 5.0,
            },
            OrderAxis::Z,
        );
        let item2 = Item::new_item(
            2,
            Vector {
                x: 1.0,
                y: 3.0,
                z: 4.0,
            },
            OrderAxis::Z,
        );

        assert_eq!(item1.cmp(&item2), Ordering::Greater);
    }

    #[test]
    fn test_item_distance() {
        let item1 = Item::new_item(
            1,
            Vector {
                x: 1.0,
                y: 3.0,
                z: 5.0,
            },
            OrderAxis::X,
        );
        let item2 = Item::new_item(
            1,
            Vector {
                x: 2.0,
                y: 3.0,
                z: 5.0,
            },
            OrderAxis::X,
        );

        assert_eq!(item1.distance(&item2), 1.0);
    }
}
