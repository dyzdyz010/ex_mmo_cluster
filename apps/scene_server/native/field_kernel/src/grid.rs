use crate::types::{Aabb, Coord};

pub(crate) fn neighbor_indices((x, y, z): Coord, aabb: Aabb) -> Vec<u16> {
    let mut indices = Vec::with_capacity(6);

    for coord in [
        (x.wrapping_sub(1), y, z),
        (x + 1, y, z),
        (x, y.wrapping_sub(1), z),
        (x, y + 1, z),
        (x, y, z.wrapping_sub(1)),
        (x, y, z + 1),
    ] {
        if local_macro_coord(coord) && in_aabb(coord, aabb) {
            indices.push(macro_index(coord));
        }
    }

    indices
}

pub(crate) fn aabb_indices(((min_x, min_y, min_z), (max_x, max_y, max_z)): Aabb) -> Vec<u16> {
    let mut indices = Vec::new();

    for x in min_x..=max_x {
        for y in min_y..=max_y {
            for z in min_z..=max_z {
                indices.push(macro_index((x, y, z)));
            }
        }
    }

    indices
}

pub(crate) fn local_macro_coord((x, y, z): Coord) -> bool {
    x < 16 && y < 16 && z < 16
}

pub(crate) fn in_aabb(
    (x, y, z): Coord,
    ((min_x, min_y, min_z), (max_x, max_y, max_z)): Aabb,
) -> bool {
    x >= min_x && x <= max_x && y >= min_y && y <= max_y && z >= min_z && z <= max_z
}

pub(crate) fn macro_index((x, y, z): Coord) -> u16 {
    x as u16 + y as u16 * 16 + z as u16 * 16 * 16
}

pub(crate) fn macro_coord(index: u16) -> Coord {
    let z = index / (16 * 16);
    let rem_after_z = index % (16 * 16);
    let y = rem_after_z / 16;
    let x = rem_after_z % 16;
    (x as u8, y as u8, z as u8)
}
