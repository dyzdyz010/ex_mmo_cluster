use rustler::NifStruct;

use crate::sorted_set::SortedSet;


#[derive(Debug, NifStruct)]
#[module = "CoordinateSystem"]
struct CoordinateSystem {
    xlist: SortedSet,
    ylist: SortedSet,
    zlist: SortedSet,
}

