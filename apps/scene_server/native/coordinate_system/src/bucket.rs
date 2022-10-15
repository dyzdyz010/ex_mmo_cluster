use std::{ptr, cmp::Ordering};

use rustler::NifStruct;

use crate::{item::Item, AddResult, SetAddResult};

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
                return idx+1;
            }

            if item > &comp_vec[idx_end] {
                return idx;
            }

            idx = (idx_end - idx_start + 1) / 2 + idx_start;
            // println!("当前idx: {}, idx_start: {}, idx_end: {}.", idx, idx_start, idx_end);
            let ele = &comp_vec[idx];
            match item.cmp(&ele) {
                std::cmp::Ordering::Greater | std::cmp::Ordering::Equal => {
                    idx_start = idx+1;
                    // let remainder = comp_vec.splice(idx + 1..comp_vec.len(), []).collect();
                    // comp_vec = remainder
                },
                std::cmp::Ordering::Less => {
                    idx_end = idx-1;
                    // let remainder = comp_vec.splice(0..idx, []).collect();
                    // comp_vec = remainder
                }
            }
        }

        return idx+1;
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
            Ordering::Greater
        } else if last_item < item {
            Ordering::Less
        } else {
            Ordering::Equal
        }
    }
}
