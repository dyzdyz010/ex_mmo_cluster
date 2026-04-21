//! movement_core: single-source-of-truth movement integrator shared by the
//! scene_server NIF and the bevy_client. Zero runtime dependencies — this is
//! a pure kinematic library (f64, fixed dt, deterministic).

pub mod ack;
pub mod input;
pub mod integrator;
pub mod mode;
pub mod profile;
pub mod state;

pub use ack::{CorrectionFlags, MovementAck};
pub use input::{InputFrame, MOVEMENT_FLAG_BRAKE};
pub use mode::MovementMode;
pub use profile::MovementProfile;
pub use state::MovementState;

pub(crate) mod math;
