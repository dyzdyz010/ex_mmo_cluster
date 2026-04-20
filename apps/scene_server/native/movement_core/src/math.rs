//! Internal f64 vector helpers. Kept private to the crate so consumers deal
//! in `[f64;2]` / `[f64;3]` and the math stays bit-identical with the legacy
//! movement_engine implementation.

pub type Vec2 = [f64; 2];
pub type Vec3 = [f64; 3];

pub fn normalize_or_zero(v: Vec2) -> Vec2 {
    let mag = (v[0] * v[0] + v[1] * v[1]).sqrt();
    if mag <= 1.0e-6 {
        [0.0, 0.0]
    } else {
        [v[0] / mag, v[1] / mag]
    }
}

pub fn magnitude_sq(v: Vec3) -> f64 {
    v[0] * v[0] + v[1] * v[1] + v[2] * v[2]
}

pub fn magnitude(v: Vec3) -> f64 {
    magnitude_sq(v).sqrt()
}

pub fn add(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

pub fn sub(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

pub fn mul(v: Vec3, s: f64) -> Vec3 {
    [v[0] * s, v[1] * s, v[2] * s]
}

pub fn div(v: Vec3, s: f64) -> Vec3 {
    [v[0] / s, v[1] / s, v[2] / s]
}

pub fn normalize_vec3(v: Vec3) -> Vec3 {
    let mag = magnitude(v);
    if mag <= 1.0e-6 {
        [0.0, 0.0, 0.0]
    } else {
        div(v, mag)
    }
}

pub fn clamp_vec3(v: Vec3, max_length: f64) -> Vec3 {
    if magnitude(v) <= max_length {
        v
    } else {
        mul(normalize_vec3(v), max_length)
    }
}
