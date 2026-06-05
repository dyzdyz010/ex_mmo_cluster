use rustler::NifStruct;

use crate::{
    configuration::Configuration,
    item::Item,
    sorted_set::SortedSet,
    AddResult, RemoveResult, SetAddResult, SetRemoveResult, UpdateResult, types::{Vector, OrderAxis},
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
        // scene-rust-1:移除 rayon。这里只对固定 3 条轴(X/Y/Z)做插入,
        // 并行 3 个元素的收益远小于线程池调度开销;且该方法在 dirty scheduler
        // 线程上被调用,不应再开 rayon 线程池。改为顺序迭代,语义等价。
        let jobs: Vec<SetAddResult> = self
            .axes
            .iter_mut()
            .enumerate()
            .map(|(idx, ss)| {
                ss.add(Item {
                    cid: item.cid,
                    coord: item.coord.clone(),
                    order_type: OrderAxis::axis_by_index(idx),
                })
            })
            .collect();

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
        // scene-rust-1:同 add,移除 rayon,固定 3 轴顺序迭代。
        let jobs: Vec<SetRemoveResult> = self
            .axes
            .iter_mut()
            .enumerate()
            .map(|(idx, ss)| {
                ss.remove(&Item {
                    cid: item.cid,
                    coord: item.coord.clone(),
                    order_type: OrderAxis::axis_by_index(idx),
                })
            })
            .collect();

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

    pub fn update(&mut self, item: &mut Item, new_position: Vector) -> UpdateResult {
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

    // pub fn update_new(&mut self, item: &mut Item, new_position: Vector) -> UpdateResult {
    //     let mut jobs: Vec<Result<Item, i32>> = Vec::with_capacity(3);
    //     self.axes.par_iter_mut().enumerate().map(|(idx, ss)| {
    //         return ss.update_with_coordinate(&Item {
    //             cid: item.cid,
    //             coord: item.coord.clone(),
    //             order_type: OrderAxis::axis_by_index(idx),
    //         }, new_position);
    //     }).collect_into_vec(&mut jobs);

    //     let result = match(jobs[0], jobs[1], jobs[2]) {
    //         (Ok(_), Ok(_), Ok(_)) => UpdateResult::Updated(0, 0, 0),
    //         (_, _, _) => UpdateResult::Error
    //     };

    //     result
    // }

    pub fn items_within_distance_for_item<'a>(&'a self, item: &Item, distance: f64) -> Vec<&'a Item> {
        // scene-rust-1:移除 rayon,3 轴顺序迭代后合并去重。
        let mut items: Vec<&Item> = self.axes.iter().map(|set|
            set.items_within_distance_for_item(item, distance)
        ).flat_map(|a| a.to_vec()).collect();

        items.sort_by(|x, y| x.cid.cmp(&y.cid));
        items.dedup_by(|a, b| a.cid == b.cid);

        let idx = items.binary_search_by(|x| x.cid.cmp(&item.cid)).unwrap();
        items.remove(idx);

        items
    }
}
