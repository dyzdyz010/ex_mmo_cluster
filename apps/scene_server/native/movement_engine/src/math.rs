pub type Vec2 = (f64, f64);
pub type Vec3 = (f64, f64, f64);

pub fn normalize_or_zero((x, y): Vec2) -> Vec2 {
    let magnitude = (x * x + y * y).sqrt();

    if magnitude <= 1.0e-6 {
        (0.0, 0.0)
    } else {
        (x / magnitude, y / magnitude)
    }
}

pub fn magnitude_sq((x, y, z): Vec3) -> f64 {
    x * x + y * y + z * z
}

pub fn magnitude(vector: Vec3) -> f64 {
    magnitude_sq(vector).sqrt()
}

pub fn add((ax, ay, az): Vec3, (bx, by, bz): Vec3) -> Vec3 {
    (ax + bx, ay + by, az + bz)
}

pub fn sub((ax, ay, az): Vec3, (bx, by, bz): Vec3) -> Vec3 {
    (ax - bx, ay - by, az - bz)
}

pub fn mul((x, y, z): Vec3, scalar: f64) -> Vec3 {
    (x * scalar, y * scalar, z * scalar)
}

pub fn div(vector: Vec3, scalar: f64) -> Vec3 {
    (vector.0 / scalar, vector.1 / scalar, vector.2 / scalar)
}

pub fn normalize_vec3(vector: Vec3) -> Vec3 {
    let magnitude = magnitude(vector);

    if magnitude <= 1.0e-6 {
        (0.0, 0.0, 0.0)
    } else {
        div(vector, magnitude)
    }
}

pub fn clamp_vec3(vector: Vec3, max_length: f64) -> Vec3 {
    if magnitude(vector) <= max_length {
        vector
    } else {
        mul(normalize_vec3(vector), max_length)
    }
}
