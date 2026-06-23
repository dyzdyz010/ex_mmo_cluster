//! Live voxel pick — DDA raymarch against the **server-authoritative** chunk
//! occupancy, for in-scene building. The offline build path raycasts the local
//! `VoxelWorld` (despawned in a live scene); live building must hit the authority
//! store's chunks instead. Pure: takes an occupancy closure over GLOBAL macro
//! coords and returns the first hit cell + the face it was entered through (the
//! adjacency a place targets). Amanatides–Woo voxel traversal — O(ray length in
//! cells), not O(loaded cells).

/// Render units per macro cell (mirrors `chunk_render::MACRO_RENDER_SIZE`). A
/// global macro `g` occupies render-space AABB `[g*100, (g+1)*100]`.
pub const MACRO_RENDER_SIZE: f32 = 100.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LivePick {
    /// Global macro coord of the first occupied cell hit.
    pub occupied_macro: [i32; 3],
    /// Unit face normal of the face the ray entered through (components in {-1,0,1}).
    pub face_normal: [i32; 3],
}

impl LivePick {
    /// The cell adjacent across the hit face — where a place lands.
    pub fn adjacent_macro(&self) -> [i32; 3] {
        [
            self.occupied_macro[0] + self.face_normal[0],
            self.occupied_macro[1] + self.face_normal[1],
            self.occupied_macro[2] + self.face_normal[2],
        ]
    }
}

/// Marches the ray (render-space `origin`/`dir`) through macro cells, returning the
/// first cell for which `is_occupied(global_macro)` is true (within `max_render_dist`)
/// plus the entry face normal. The ray's own starting cell is **skipped** (the camera
/// sits in air; this avoids an ambiguous self-face and lets you build against the
/// terrain you're looking at, not the block you stand in).
pub fn pick_voxel(
    origin: [f32; 3],
    dir: [f32; 3],
    max_render_dist: f32,
    is_occupied: impl Fn([i32; 3]) -> bool,
) -> Option<LivePick> {
    let len = (dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]).sqrt();
    if !len.is_finite() || len < 1e-6 {
        return None;
    }
    let d = [dir[0] / len, dir[1] / len, dir[2] / len];
    // Position in macro units.
    let p = [
        origin[0] / MACRO_RENDER_SIZE,
        origin[1] / MACRO_RENDER_SIZE,
        origin[2] / MACRO_RENDER_SIZE,
    ];
    let mut cell = [
        p[0].floor() as i32,
        p[1].floor() as i32,
        p[2].floor() as i32,
    ];

    let mut step = [0i32; 3];
    let mut t_max = [f32::INFINITY; 3];
    let mut t_delta = [f32::INFINITY; 3];
    for a in 0..3 {
        if d[a] > 1e-9 {
            step[a] = 1;
            t_max[a] = (cell[a] as f32 + 1.0 - p[a]) / d[a];
            t_delta[a] = 1.0 / d[a];
        } else if d[a] < -1e-9 {
            step[a] = -1;
            t_max[a] = (cell[a] as f32 - p[a]) / d[a]; // neg / neg = positive
            t_delta[a] = 1.0 / -d[a];
        }
    }

    let max_t = max_render_dist / MACRO_RENDER_SIZE;
    // Generous iteration bound (3 axes worth of cells along the ray).
    let max_steps = ((max_t.ceil() as i64 + 2) * 3).clamp(1, 4096);

    for _ in 0..max_steps {
        // Step along the axis with the nearest boundary.
        let axis = if t_max[0] <= t_max[1] && t_max[0] <= t_max[2] {
            0
        } else if t_max[1] <= t_max[2] {
            1
        } else {
            2
        };
        if t_max[axis] > max_t {
            return None;
        }
        cell[axis] += step[axis];
        t_max[axis] += t_delta[axis];
        if is_occupied(cell) {
            let mut face = [0i32; 3];
            face[axis] = -step[axis];
            return Some(LivePick {
                occupied_macro: cell,
                face_normal: face,
            });
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const M: f32 = MACRO_RENDER_SIZE;

    #[test]
    fn picks_first_occupied_along_plus_x_with_entry_face() {
        // Origin in air at macro x=-1 (render -50), looking +x; block at macro 3.
        let pick = pick_voxel([-50.0, 50.0, 50.0], [1.0, 0.0, 0.0], 1000.0, |c| {
            c == [3, 0, 0]
        })
        .expect("hit");
        assert_eq!(pick.occupied_macro, [3, 0, 0]);
        assert_eq!(pick.face_normal, [-1, 0, 0]); // entered through -x face
        assert_eq!(pick.adjacent_macro(), [2, 0, 0]); // place lands one cell back
    }

    #[test]
    fn picks_floor_looking_down() {
        // Camera above a floor at macro y=0, looking straight down.
        let pick = pick_voxel([50.0, 550.0, 50.0], [0.0, -1.0, 0.0], 2000.0, |c| c[1] == 0)
            .expect("hit");
        assert_eq!(pick.occupied_macro, [0, 0, 0]);
        assert_eq!(pick.face_normal, [0, 1, 0]); // entered through the top (+y) face
        assert_eq!(pick.adjacent_macro(), [0, 1, 0]);
    }

    #[test]
    fn misses_when_nothing_in_range() {
        assert!(pick_voxel([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 500.0, |_| false).is_none());
    }

    #[test]
    fn respects_max_distance() {
        // Block is 10 macros away (1000 render units); ray capped at 300 → miss.
        let occ = |c: [i32; 3]| c == [10, 0, 0];
        assert!(pick_voxel([5.0, 50.0, 50.0], [1.0, 0.0, 0.0], 300.0, occ).is_none());
        assert!(pick_voxel([5.0, 50.0, 50.0], [1.0, 0.0, 0.0], 1100.0, occ).is_some());
    }

    #[test]
    fn diagonal_ray_picks_nearest_face() {
        // Diagonal down-forward ray into a solid floor slab at y=0 (all x,z).
        let pick = pick_voxel([5.0, 350.0, 5.0], [0.3, -1.0, 0.0], 5000.0, |c| c[1] <= 0)
            .expect("hit");
        assert_eq!(pick.occupied_macro[1], 0);
        // Entered through the top face (came from above).
        assert_eq!(pick.face_normal, [0, 1, 0]);
    }

    #[test]
    fn degenerate_direction_is_none() {
        assert!(pick_voxel([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], 100.0, |_| true).is_none());
    }
}
