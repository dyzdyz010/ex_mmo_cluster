use std::cmp::min;

use rustler::NifStruct;

use crate::{
    bucket::Bucket, configuration::Configuration, item::Item, FindResult, SetAddResult,
    SetRemoveResult,
};

#[derive(Debug, NifStruct, Clone)]
#[module = "SortedSet"]
pub struct SortedSet {
    configuration: Configuration,
    buckets: Vec<Bucket>,
    size: usize,
}

impl SortedSet {
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
            Err(idx) => min(idx, self.buckets.len() - 1),
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
}

impl Default for SortedSet {
    fn default() -> Self {
        Self::new(Configuration::default())
    }
}
