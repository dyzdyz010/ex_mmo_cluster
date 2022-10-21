use std::{cmp::Ordering, ptr};

use rayon::prelude::{IntoParallelRefIterator, ParallelIterator};
use rustler::NifStruct;

use crate::{item::Item, SetAddResult, SetRemoveResult};

#[derive(NifStruct, Clone, Debug)]
#[module = "Bucket"]
pub struct Bucket {
    pub data: Vec<Item>,
}

impl Bucket {
    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn add(&mut self, item: Item) -> SetAddResult {
        match self.data.binary_search_by_key(&item.cid, |ele| ele.cid) {
            Ok(idx) => SetAddResult::Duplicate(idx),
            Err(_) => {
                // println!("无重复元素，可以插入。");
                let insert_idx = self.binary_search(&item);
                // println!("无重复元素，可以插入。");
                self.data.insert(insert_idx, item);
                SetAddResult::Added(insert_idx)
            }
        }
    }

    pub fn remove(&mut self, item: Item) -> SetRemoveResult {
        match self.data.binary_search(&item) {
            Ok(idx) => {
                self.data.remove(idx);
                SetRemoveResult::Removed(idx)
            }
            Err(_) => SetRemoveResult::NotFound,
        }
    }

    pub fn split(&mut self) -> Bucket {
        let curr_len = self.data.len();
        let at = curr_len / 2;

        let other_len = self.data.len() - at;
        let mut other = Vec::with_capacity(curr_len);

        // Unsafely `set_len` and copy items to `other`.
        unsafe {
            self.data.set_len(at);
            other.set_len(other_len);

            ptr::copy_nonoverlapping(self.data.as_ptr().add(at), other.as_mut_ptr(), other.len());
        }

        Bucket { data: other }
    }

    fn binary_search(&mut self, item: &Item) -> usize {
        if self.len() == 0 || item < self.data.first().unwrap() {
            // println!("最头部");
            return 0;
        }

        if item > self.data.last().unwrap() {
            // println!("最尾部");
            return self.len();
        }

        let comp_vec: &Vec<Item> = &self.data;
        let mut idx_start: usize = 0;
        let mut idx_end: usize = self.len() - 1;
        let mut idx: usize = 0;
        while idx_end >= idx_start {
            if item < &comp_vec[idx_start] {
                return idx + 1;
            }

            if item > &comp_vec[idx_end] {
                return idx;
            }

            idx = (idx_end - idx_start + 1) / 2 + idx_start;
            // println!("当前idx: {}, idx_start: {}, idx_end: {}.", idx, idx_start, idx_end);
            let ele = &comp_vec[idx];
            match item.cmp(&ele) {
                std::cmp::Ordering::Greater | std::cmp::Ordering::Equal => {
                    idx_start = idx + 1;
                    // let remainder = comp_vec.splice(idx + 1..comp_vec.len(), []).collect();
                    // comp_vec = remainder
                }
                std::cmp::Ordering::Less => {
                    idx_end = idx - 1;
                    // let remainder = comp_vec.splice(0..idx, []).collect();
                    // comp_vec = remainder
                }
            }
        }

        return idx + 1;
    }

    pub fn item_compare(&self, item: &Item) -> Ordering {
        let first_item = match self.data.first() {
            Some(f) => f,
            None => return Ordering::Equal,
        };

        let last_item = match self.data.last() {
            Some(l) => l,
            None => return Ordering::Equal,
        };

        if item < first_item {
            // println!("Bucket 大");
            Ordering::Greater
        } else if last_item < item {
            // println!("Bucket 小");
            Ordering::Less
        } else {
            Ordering::Equal
        }
    }

    pub fn item_update(&mut self, old_item: &Item, new_item: &Item) -> bool {
        let idx1 = match self.data.binary_search(old_item) {
            Ok(oidx) => oidx,
            Err(eidx) => eidx,
        };
        let idx2 = self.binary_search(new_item);

        if idx1 == idx2 {
            return true;
        } else if idx1 < idx2 {
            if idx2 - idx1 == 1 {
                self.data[idx1].coord = new_item.coord;
                return true;
            }
            unsafe {
                ptr::copy(
                    self.data.as_ptr().add(idx1 + 1),
                    self.data.as_mut_ptr().add(idx1),
                    idx2 - 1 - idx1,
                );
                self.data[idx2 - 1] = new_item.clone();
            }
        } else {
            unsafe {
                ptr::copy(
                    self.data.as_ptr().add(idx1 - 1),
                    self.data.as_mut_ptr().add(idx1),
                    idx1 - idx2,
                );
                self.data[idx1] = new_item.clone();
            }
        }

        return true;
    }

    pub fn items_within_distance_for_item(&self, item: &Item, distance: f64) -> Vec<&Item> {
        let items: Vec<&Item> = self
            .data
            .par_iter()
            .filter(|it| {
                println!("距离：{}", item.distance(it));
                item.distance(it) <= distance && item.distance(it) != 0.0
            })
            .collect();

        items
    }
}

#[cfg(test)]
mod tests {
    use crate::item::{CoordTuple, OrderAxis};

    use super::*;
    use std::cmp::Ordering;

    #[test]
    fn test_item_compare_empty_bucket() {
        let bucket = Bucket { data: Vec::new() };

        let item = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::X,
        );

        assert_eq!(bucket.item_compare(&item), Ordering::Equal);
    }

    #[test]
    fn test_item_compare_when_less_than_first_item() {
        let mut bucket = Bucket { data: Vec::new() };
        let first_item = Item::new_item(
            1,
            CoordTuple {
                x: 10.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::X,
        );
        assert_eq!(bucket.add(first_item), SetAddResult::Added(0));

        let item = Item::new_item(
            2,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::X,
        );

        assert_eq!(bucket.item_compare(&item), Ordering::Greater);
    }

    #[test]
    fn test_item_compare_when_equal_to_first_item() {
        let mut bucket = Bucket { data: Vec::new() };
        let first_item = Item::new_item(
            1,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::X,
        );
        let item = first_item.clone();

        assert_eq!(bucket.add(first_item), SetAddResult::Added(0));
        assert_eq!(bucket.item_compare(&item), Ordering::Equal);
    }

    #[test]
    fn test_item_compare_when_greater_than_last_item() {
        let mut bucket = Bucket { data: Vec::new() };

        assert_eq!(
            bucket.add(Item::new_item(
                1,
                CoordTuple {
                    x: 1.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(0)
        );
        assert_eq!(
            bucket.add(Item::new_item(
                2,
                CoordTuple {
                    x: 2.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(1)
        );
        assert_eq!(
            bucket.add(Item::new_item(
                3,
                CoordTuple {
                    x: 3.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(2)
        );

        let item = Item::new_item(
            4,
            CoordTuple {
                x: 5.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::X,
        );

        assert_eq!(bucket.item_compare(&item), Ordering::Less);
    }

    #[test]
    fn test_item_compare_when_equal_to_last_item() {
        let mut bucket = Bucket { data: Vec::new() };

        assert_eq!(
            bucket.add(Item::new_item(
                1,
                CoordTuple {
                    x: 1.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(0)
        );
        assert_eq!(
            bucket.add(Item::new_item(
                2,
                CoordTuple {
                    x: 2.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(1)
        );
        assert_eq!(
            bucket.add(Item::new_item(
                3,
                CoordTuple {
                    x: 3.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(2)
        );

        let item = Item::new_item(
            4,
            CoordTuple {
                x: 3.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::X,
        );

        assert_eq!(bucket.item_compare(&item), Ordering::Equal);
    }

    #[test]
    fn test_item_between_first_and_last_duplicate() {
        let mut bucket = Bucket { data: Vec::new() };

        assert_eq!(
            bucket.add(Item::new_item(
                1,
                CoordTuple {
                    x: 1.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(0)
        );
        assert_eq!(
            bucket.add(Item::new_item(
                2,
                CoordTuple {
                    x: 2.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(1)
        );
        assert_eq!(
            bucket.add(Item::new_item(
                3,
                CoordTuple {
                    x: 3.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(2)
        );

        let item = Item::new_item(
            4,
            CoordTuple {
                x: 1.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::X,
        );

        assert_eq!(bucket.item_compare(&item), Ordering::Equal);
    }

    #[test]
    fn test_item_between_first_and_last_unique() {
        let mut bucket = Bucket { data: Vec::new() };

        assert_eq!(
            bucket.add(Item::new_item(
                1,
                CoordTuple {
                    x: 2.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(0)
        );
        assert_eq!(
            bucket.add(Item::new_item(
                2,
                CoordTuple {
                    x: 4.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(1)
        );
        assert_eq!(
            bucket.add(Item::new_item(
                3,
                CoordTuple {
                    x: 6.0,
                    y: 2.0,
                    z: 3.0
                },
                OrderAxis::X
            )),
            SetAddResult::Added(2)
        );

        let item = Item::new_item(
            4,
            CoordTuple {
                x: 3.0,
                y: 2.0,
                z: 3.0,
            },
            OrderAxis::X,
        );

        assert_eq!(bucket.item_compare(&item), Ordering::Equal);
    }

    #[test]
    fn test_split_bucket_with_no_items() {
        let mut bucket = Bucket { data: vec![] };

        assert_eq!(bucket.data.len(), 0);
        assert_eq!(bucket.data.capacity(), 0);

        let other = bucket.split();

        assert_eq!(bucket.data.len(), 0);
        assert_eq!(bucket.data.capacity(), 0);

        assert_eq!(other.data.len(), 0);
        assert_eq!(other.data.capacity(), 0);
    }

    #[test]
    fn test_split_bucket_with_odd_number_of_items() {
        let mut bucket = Bucket {
            data: vec![
                Item::new_item(
                    0,
                    CoordTuple {
                        x: 0.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    1,
                    CoordTuple {
                        x: 1.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    2,
                    CoordTuple {
                        x: 2.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    3,
                    CoordTuple {
                        x: 3.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    4,
                    CoordTuple {
                        x: 4.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    5,
                    CoordTuple {
                        x: 5.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    6,
                    CoordTuple {
                        x: 6.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    7,
                    CoordTuple {
                        x: 7.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    8,
                    CoordTuple {
                        x: 8.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
            ],
        };

        // There were 9 items placed in the bucket, it should have length & capacity of 9
        assert_eq!(bucket.data.len(), 9);
        assert_eq!(bucket.data.capacity(), 9);

        let other = bucket.split();

        // Initial bucket should retain the same capacity but with half the length.
        assert_eq!(bucket.data.len(), 4);
        assert_eq!(bucket.data.capacity(), 9);

        // Other bucket should have the same capacity as the initial bucket and half the length.
        assert_eq!(other.data.len(), 5);
        assert_eq!(other.data.capacity(), 9);
    }

    #[test]
    fn test_split_bucket_with_even_number_of_items() {
        let mut bucket = Bucket {
            data: vec![
                Item::new_item(
                    0,
                    CoordTuple {
                        x: 0.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    1,
                    CoordTuple {
                        x: 1.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    2,
                    CoordTuple {
                        x: 2.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    3,
                    CoordTuple {
                        x: 3.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    4,
                    CoordTuple {
                        x: 4.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    5,
                    CoordTuple {
                        x: 5.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    6,
                    CoordTuple {
                        x: 6.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    7,
                    CoordTuple {
                        x: 7.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    8,
                    CoordTuple {
                        x: 8.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    9,
                    CoordTuple {
                        x: 9.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
            ],
        };

        // There were 10 items placed in the bucket, it should have length & capacity of 10
        assert_eq!(bucket.data.len(), 10);
        assert_eq!(bucket.data.capacity(), 10);

        let other = bucket.split();

        // Initial bucket should retain the same capacity but with half the length.
        assert_eq!(bucket.data.len(), 5);
        assert_eq!(bucket.data.capacity(), 10);

        // Other bucket should have the same capacity as the initial bucket and half the length.
        assert_eq!(other.data.len(), 5);
        assert_eq!(other.data.capacity(), 10);
    }

    #[test]
    fn test_items_within_distance_from_item() {
        let bucket = Bucket {
            data: vec![
                Item::new_item(
                    0,
                    CoordTuple {
                        x: 0.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    1,
                    CoordTuple {
                        x: 1.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    2,
                    CoordTuple {
                        x: 2.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    3,
                    CoordTuple {
                        x: 3.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
                Item::new_item(
                    4,
                    CoordTuple {
                        x: 4.0,
                        y: 2.0,
                        z: 3.0,
                    },
                    OrderAxis::X,
                ),
            ],
        };

        let item = &bucket.data[2];
        let items = bucket.items_within_distance_for_item(item, 1.0);
        assert_eq!(items.len(), 2);

        let items = bucket.items_within_distance_for_item(item, 2.0);
        assert_eq!(items.len(), 4);
    }
}
