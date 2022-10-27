use crate::types::Vector;

pub fn calculate_coordinate(
    old_timestamp: i64,
    new_timestamp: i64,
    location: Vector,
    velocity: Vector,
) -> Vector {
    let mut result: Vector = location.clone();

    if velocity == (Vector{x: 0.0, y: 0.0, z: 0.0}) {
        result = location;
    } else {
        let time = (new_timestamp - old_timestamp) as f64 / 1000.0;
        result.x = location.x + velocity.x * time;
        result.y = location.y + velocity.y * time;
        result.z = location.z + velocity.z * time;
    }

    return result;
}
