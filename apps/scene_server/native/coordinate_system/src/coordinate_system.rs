use rustler::NifStruct;

use crate::{sorted_set::SortedSet, configuration::Configuration, item::{Item, OrderAxis}, AddResult, SetAddResult, SetRemoveResult, RemoveResult};


#[derive(Debug, NifStruct, Clone)]
#[module = "CoordinateSystem"]
pub struct CoordinateSystem {
    xlist: SortedSet,
    ylist: SortedSet,
    zlist: SortedSet,
}

impl CoordinateSystem {
    pub fn new(configuration: Configuration) -> CoordinateSystem {
        let xlist = SortedSet::new(configuration);
        let ylist = SortedSet::new(configuration);
        let zlist = SortedSet::new(configuration);

        CoordinateSystem { xlist, ylist, zlist }
    }

    pub fn add(&mut self, item: &Item) -> AddResult {
        let mut new_item_x = item.clone();
        new_item_x.order_type = OrderAxis::X;
        let mut new_item_y = item.clone();
        new_item_y.order_type = OrderAxis::Y;
        let mut new_item_z = item.clone();
        new_item_z.order_type = OrderAxis::Z;

        let xjob = self.xlist.add(new_item_x);
        let yjob = self.ylist.add(new_item_y);
        let zjob = self.zlist.add(new_item_z);

        // println!("插入X、Y、Z轴。");

        let result = match (xjob, yjob, zjob) {
            (SetAddResult::Added(ix), SetAddResult::Added(iy), SetAddResult::Added(iz)) => AddResult::Added(ix, iy, iz),
            (rx, ry, rz) => AddResult::Error((rx, ry, rz)),
        };

        result
    }

    pub fn remove(&mut self, item: &Item) -> RemoveResult {
        let xjob = self.xlist.remove(item);
        let yjob = self.ylist.remove(item);
        let zjob = self.zlist.remove(item);

        let result = match (xjob, yjob, zjob) {
            (SetRemoveResult::Removed(ix), SetRemoveResult::Removed(iy), SetRemoveResult::Removed(iz)) => RemoveResult::Removed(ix, iy, iz),
            (rx, ry, rz) => RemoveResult::Error((rx, ry, rz)),
        };

        result
    }
}

// unsafe impl NifReturnable for CoordinateSystem {
//     unsafe fn into_returned(self, env: rustler::Env) -> rustler::codegen_runtime::NifReturned {
//         self.into_returned(env)
//     }
// }