use rustler::NifStruct;

use crate::{item::Item, AddResult};

#[derive(NifStruct, Clone)]
#[module = "Bucket"]
pub struct Bucket {
    pub data: Vec<Item>,
}

impl Bucket {
    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn add(&mut self, item: Item) -> AddResult {
        match self.data.binary_search_by_key(&item.cid, |ele| ele.cid) {
            Ok(idx) => AddResult::Duplicate(idx),
            Err(_) => {
                let insert_idx = self.binary_insert_position_search(&item);
                self.data.insert(insert_idx, item);
                AddResult::Added(insert_idx)
            }
        }
    }

    fn binary_insert_position_search(&mut self, item: &Item) -> usize {
        if self.len() == 0 || item < self.data.first().unwrap() {
            println!("最头部");
            return 0;
        }

        if item > self.data.last().unwrap() {
            println!("最尾部");
            return self.len();
        }

        let mut comp_vec: Vec<Item> = self.data.clone();
        let mut idx: usize = 0;
        while comp_vec.len() > 0 {
            println!("当前idx: {}", idx);
            if item < comp_vec.first().unwrap() {
                return idx+1;
            }

            if item > comp_vec.last().unwrap() {
                return idx;
            }

            idx = comp_vec.len() / 2;
            let ele = &comp_vec[idx];
            match item.cmp(&ele) {
                std::cmp::Ordering::Greater | std::cmp::Ordering::Equal => {
                    let remainder = comp_vec.splice(idx + 1..comp_vec.len(), []).collect();
                    comp_vec = remainder
                },
                std::cmp::Ordering::Less => {
                    let remainder = comp_vec.splice(0..idx, []).collect();
                    comp_vec = remainder
                }
            }
        }

        return idx;
    }
}
