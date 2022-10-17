use rayon::prelude::*;
use rustler::NifStruct;

use crate::{
    configuration::Configuration,
    item::{CoordTuple, Item, OrderAxis},
    sorted_set::SortedSet,
    AddResult, RemoveResult, SetAddResult, SetRemoveResult, UpdateResult,
};

#[derive(Debug, NifStruct, Clone)]
#[module = "CoordinateSystem"]
pub struct CoordinateSystem {
    configuration: Configuration,
    axes: Vec<SortedSet>,
}

impl CoordinateSystem {
    pub fn new(configuration: Configuration) -> CoordinateSystem {
        let xlist = SortedSet::new(configuration);
        let ylist = SortedSet::new(configuration);
        let zlist = SortedSet::new(configuration);

        let mut system = CoordinateSystem {
            configuration,
            axes: Vec::with_capacity(3),
        };

        system.axes.push(xlist);
        system.axes.push(ylist);
        system.axes.push(zlist);

        system
    }

    pub fn add(&mut self, item: &Item) -> AddResult {
        let mut jobs: Vec<SetAddResult> = Vec::with_capacity(3);

        self.axes
            .par_iter_mut()
            .enumerate()
            .map(|(idx, ss)| {
                return ss.add(Item {
                    cid: item.cid,
                    coord: item.coord.clone(),
                    order_type: OrderAxis::axis_by_index(idx),
                });
            })
            .collect_into_vec(&mut jobs);

        // println!("插入X、Y、Z轴。");

        let result = match (jobs[0], jobs[1], jobs[2]) {
            (SetAddResult::Added(ix), SetAddResult::Added(iy), SetAddResult::Added(iz)) => {
                AddResult::Added(ix, iy, iz)
            }
            (rx, ry, rz) => AddResult::Error((rx, ry, rz)),
        };

        result
    }

    pub fn remove(&mut self, item: &mut Item) -> RemoveResult {
        let mut jobs: Vec<SetRemoveResult> = Vec::with_capacity(3);

        self.axes
            .par_iter_mut()
            .enumerate()
            .map(|(idx, ss)| {
                return ss.remove(&Item {
                    cid: item.cid,
                    coord: item.coord.clone(),
                    order_type: OrderAxis::axis_by_index(idx),
                });
            })
            .collect_into_vec(&mut jobs);

        let result = match (jobs[0], jobs[1], jobs[2]) {
            (
                SetRemoveResult::Removed(ix),
                SetRemoveResult::Removed(iy),
                SetRemoveResult::Removed(iz),
            ) => RemoveResult::Removed(ix, iy, iz),
            (rx, ry, rz) => RemoveResult::Error((rx, ry, rz)),
        };

        result
    }

    pub fn update(&mut self, item: &mut Item, new_position: CoordTuple) -> UpdateResult {
        match self.remove(item) {
            RemoveResult::Error(_) => return UpdateResult::Error,
            _ => {}
        };
        item.coord = new_position;

        match self.add(item) {
            AddResult::Added(idxx, idxy, idxz) => UpdateResult::Updated(idxx, idxy, idxz),
            AddResult::Error(_) => UpdateResult::Error,
        }
    }

    pub fn items_within_distance_for_item<'a>(&'a self, item: &Item, distance: f64) -> Vec<&Item> {
        let mut items: Vec<&Item> = self.axes.par_iter().map(|set|
            set.items_within_distance_for_item(item, distance)
        ).flat_map(|a| a.to_vec()).collect();
        items.dedup_by(|a, b| a.cid == b.cid);

        items
    }
}
