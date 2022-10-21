use std::cmp::min;

use rayon::prelude::{IndexedParallelIterator, IntoParallelRefIterator, ParallelIterator};
use rustler::NifStruct;

use crate::{
    bucket::Bucket,
    configuration::Configuration,
    item::{CoordTuple, Item},
    FindResult, SetAddResult, SetRemoveResult,
};

#[derive(Debug, NifStruct, Clone)]
#[module = "SortedSet"]
pub struct SortedSet {
    configuration: Configuration,
    buckets: Vec<Bucket>,
    size: usize,
}

impl<'a> SortedSet {
    pub fn empty(configuration: Configuration) -> SortedSet {
        if configuration.bucket_capacity < 1 {
            panic!("SortedSet max_bucket_size must be greater than 0");
        }

        let buckets = Vec::with_capacity(configuration.set_capacity);

        SortedSet {
            configuration,
            buckets,
            size: 0,
        }
    }

    pub fn new(configuration: Configuration) -> SortedSet {
        let mut result = SortedSet::empty(configuration);
        result.buckets.push(Bucket {
            data: Vec::with_capacity(result.configuration.bucket_capacity + 1),
        });

        result
    }

    #[inline]
    pub fn find_bucket_index(&self, item: &Item) -> usize {
        match self
            .buckets
            .binary_search_by(|bucket| bucket.item_compare(item))
        {
            Ok(idx) => idx,
            Err(idx) => {
                // println!("未找到：{}", idx);
                min(idx, self.buckets.len() - 1)
            }
        }
    }

    pub fn find_index(&self, item: &Item) -> FindResult {
        let bucket_idx = self.find_bucket_index(item);

        match self.buckets[bucket_idx].data.binary_search(&item) {
            Ok(idx) => FindResult::Found {
                bucket_idx,
                inner_idx: idx,
                idx: self.effective_index(bucket_idx, idx),
            },
            Err(_) => FindResult::NotFound,
        }
    }

    #[inline]
    fn effective_index(&self, bucket: usize, index: usize) -> usize {
        let buckets = &self.buckets[0..bucket];
        let result = buckets.into_iter().fold(0, |a, b| a + b.len()) + index;

        result
    }

    pub fn add(&mut self, item: Item) -> SetAddResult {
        // println!("插入元素。");
        let bucket_idx = self.find_bucket_index(&item);
        // println!("Bucket索引：{}", bucket_idx);

        match self.buckets[bucket_idx].add(item) {
            SetAddResult::Added(idx) => {
                // println!("插入成功。");
                let effective_idx = self.effective_index(bucket_idx, idx);
                let bucket_len = self.buckets[bucket_idx].len();

                if bucket_len >= self.configuration.bucket_capacity + 1 {
                    let new_bucket = self.buckets[bucket_idx].split();
                    // println!("分裂！");
                    self.buckets.insert(bucket_idx + 1, new_bucket);
                }

                self.size += 1;

                SetAddResult::Added(effective_idx)
            }
            SetAddResult::Duplicate(idx) => {
                SetAddResult::Duplicate(self.effective_index(bucket_idx, idx))
            }
        }
    }

    pub fn remove(&mut self, item: &Item) -> SetRemoveResult {
        match self.find_index(item) {
            FindResult::Found {
                bucket_idx,
                inner_idx,
                idx,
            } => {
                if self.size == 0 {
                    panic!(
                        "Just found item {:?} but size is 0, internal structure error \n
                                    Bucket Index: {:?} \n
                                    Inner Index: {:?} \n
                                    Effective Index: {:?}\n
                                    Buckets: {:?}",
                        item, bucket_idx, inner_idx, idx, self.buckets
                    );
                }

                self.buckets[bucket_idx].data.remove(inner_idx);

                if self.buckets.len() > 1 && self.buckets[bucket_idx].data.is_empty() {
                    self.buckets.remove(bucket_idx);
                }

                self.size -= 1;

                SetRemoveResult::Removed(idx)
            }
            FindResult::NotFound => {
                // println!("元素未找到");
                SetRemoveResult::NotFound
            }
        }
    }

    pub fn update_with_coordinate(
        &mut self,
        item: &Item,
        new_coord: CoordTuple,
    ) -> Result<Item, i32> {
        let new_item: Item = Item {
            cid: item.cid,
            coord: new_coord,
            order_type: item.order_type,
        };
        let old_idx = self.find_bucket_index(item);
        let new_idx = self.find_bucket_index(&new_item);
        if old_idx == new_idx {
            if self.buckets[old_idx].item_update(item, &new_item) {
                // println!("New Item: {:#?} \n 更新后结果：{:#?}", new_item, self);
                return Ok(new_item);
            } else {
                return Err(0);
            }
        } else {
            let remove_result = self.buckets[old_idx].remove(item.clone());
            let add_result = self.buckets[new_idx].add(new_item);
            match (remove_result, add_result) {
                (SetRemoveResult::Removed(_), SetAddResult::Added(_)) => return Ok(new_item),
                (_, _) => return Err(0),
            }
        }
    }

    pub fn items_within_distance_for_item(&'a self, item: &Item, distance: f64) -> Vec<&'a Item> {
        let mut items: Vec<&Item> = vec![];
        let within_buckets: Vec<usize> = self
            .buckets
            .par_iter()
            .enumerate()
            .filter_map(|(idx, buck)| match buck.data.len() {
                0 => return None,
                _ => {
                    match item.distance(buck.data.first().unwrap()) <= distance
                        && item.distance(buck.data.last().unwrap()) <= distance
                    {
                        true => return Some(idx),
                        false => return None,
                    }
                }
            })
            .collect();

        let mut lefthalf: Vec<&Item> = vec![];
        let mut righthalf: Vec<&Item> = vec![];

        if within_buckets.len() > 0 {
            if within_buckets.first().unwrap() >= &1 {
                lefthalf = self.buckets[within_buckets.first().unwrap() - 1]
                    .items_within_distance_for_item(item, distance);
            }
            if within_buckets.last().unwrap() <= &(self.buckets.len() - 2) {
                righthalf = self.buckets[within_buckets.last().unwrap() - 1]
                    .items_within_distance_for_item(item, distance);
            }
        }

        let mut within_items: Vec<&Item> = self
            .buckets
            .par_iter()
            .enumerate()
            .filter_map(|(idx, buck)| {
                if within_buckets.contains(&idx) {
                    return Some(&buck.data);
                } else {
                    return None;
                }
            })
            .flatten()
            .collect();

        items.append(&mut lefthalf);
        items.append(&mut within_items);
        items.append(&mut righthalf);

        return items;
    }
}

impl Default for SortedSet {
    fn default() -> Self {
        Self::new(Configuration::default())
    }
}

#[cfg(test)]
mod tests {

    use crate::item::{CoordTuple, OrderAxis};

    use super::*;

    fn get_set() -> SortedSet {
        let configuration = Configuration {
            bucket_capacity: 3,
            set_capacity: 8,
        };
        let mut set = SortedSet::new(configuration);
        set.add(Item {
            cid: 0,
            coord: CoordTuple {
                x: 1.0,
                y: 1.0,
                z: 1.0,
            },
            order_type: OrderAxis::X,
        });
        set.add(Item {
            cid: 1,
            coord: CoordTuple {
                x: 3.0,
                y: 3.0,
                z: 3.0,
            },
            order_type: OrderAxis::X,
        });
        set.add(Item {
            cid: 2,
            coord: CoordTuple {
                x: 5.0,
                y: 5.0,
                z: 5.0,
            },
            order_type: OrderAxis::X,
        });
        set.add(Item {
            cid: 3,
            coord: CoordTuple {
                x: 7.0,
                y: 7.0,
                z: 7.0,
            },
            order_type: OrderAxis::X,
        });

        set
    }

    #[test]
    fn test_find_index() {
        let set = get_set();

        let item = Item {
            cid: 1,
            coord: CoordTuple {
                x: 3.0,
                y: 3.0,
                z: 3.0,
            },
            order_type: OrderAxis::X,
        };

        let bucket_idx = set.find_bucket_index(&item);
        assert_eq!(bucket_idx, 0);

        let result = set.find_index(&item);

        assert_eq!(
            result,
            FindResult::Found {
                bucket_idx: bucket_idx,
                inner_idx: 1,
                idx: 1
            }
        );
    }

    #[test]
    fn test_update_item() {
        let mut set = get_set();

        let item = Item {
            cid: 1,
            coord: CoordTuple {
                x: 3.0,
                y: 3.0,
                z: 3.0,
            },
            order_type: OrderAxis::X,
        };

        println!("原始Set: {:#?}", set);

        let result = set
            .update_with_coordinate(
                &item,
                CoordTuple {
                    x: 4.0,
                    y: 4.0,
                    z: 4.0,
                },
            )
            .unwrap();

        assert_eq!(result.coord.x, 4.0);

        let bucket_idx = set.find_bucket_index(&item);
        assert_eq!(bucket_idx, 0);

        let result = set.find_index(&item);

        assert_eq!(
            result,
            FindResult::Found {
                bucket_idx: bucket_idx,
                inner_idx: 1,
                idx: 1
            }
        );

        let result = set
            .update_with_coordinate(
                &item,
                CoordTuple {
                    x: 6.0,
                    y: 6.0,
                    z: 6.0,
                },
            )
            .unwrap();
        assert_eq!(result.coord.x, 6.0);

        let bucket_idx = set.find_bucket_index(&item);
        assert_eq!(bucket_idx, 1);

        let result = set.find_index(&item);

        assert_eq!(
            result,
            FindResult::Found {
                bucket_idx: bucket_idx,
                inner_idx: 1,
                idx: 2
            }
        );

        let item = set
            .update_with_coordinate(
                &item,
                CoordTuple {
                    x: 0.0,
                    y: 0.0,
                    z: 0.0,
                },
            )
            .unwrap();
        println!("向后更新Set: {:#?}", set);
        assert_eq!(item.coord.x, 0.0);

        // let li = [1, 3, 5];
        // let result = li.binary_search(&-1);
        // assert_eq!(result, Err(0));

        let bucket_idx = set.find_bucket_index(&item);
        assert_eq!(bucket_idx, 0);

        println!("{}", set.buckets[0].len());

        let result = set.find_index(&item);

        assert_eq!(
            result,
            FindResult::Found {
                bucket_idx: bucket_idx,
                inner_idx: 0,
                idx: 0
            }
        );
    }
}
