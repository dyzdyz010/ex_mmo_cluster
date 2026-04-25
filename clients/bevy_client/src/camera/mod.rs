//! Orbit camera for the Bevy client.
//!
//! - `orbit` — pure data + transform math (resource, component, constants,
//!   `camera_transform_from_orbit`).
//! - `plugin` — `CameraPlugin` and the system that follows the local actor.

pub mod orbit;
pub mod plugin;

pub use orbit::{CAMERA_LOOK_HEIGHT, MainCamera, OrbitCameraState, camera_transform_from_orbit};
pub use plugin::CameraPlugin;
