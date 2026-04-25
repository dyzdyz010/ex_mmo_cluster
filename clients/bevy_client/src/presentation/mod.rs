//! Presentation-layer helpers for smoothing, camera, lightweight animation
//! state, and the `PresentationPlugin` that drives in-world actor visuals.

pub mod animation;
pub mod camera;
pub mod plugin;
pub mod smoothing;

pub use plugin::{PlayerVisual, PresentationPlugin, actor_render_position};
