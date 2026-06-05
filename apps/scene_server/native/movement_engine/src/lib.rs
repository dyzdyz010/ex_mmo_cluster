mod atoms;
mod integrator;
mod types;

use rustler::NifResult;

use crate::types::{InputFrame, MovementProfile, MovementState};

rustler::init!("Elixir.SceneServer.Native.MovementEngine");

// 调度约定(scene-rust-1):
// step 是单次定步积分,纯 f64 算术、亚微秒级,标 dirty 反而引入调度切换开销,
// 因此保留普通 NIF;replay 是对输入帧序列的 O(N) 循环积分,批量大小由调用方
// (服务端权威回放校正)决定,长窗口回放可能 >1ms,标 `schedule = "DirtyCpu"` 以防
// 阻塞普通调度器线程。

// step:单次确定性积分(单 tick),亚微秒级纯算术 → 保留普通 NIF。
#[rustler::nif]
fn step(
    state: MovementState,
    input_frame: InputFrame,
    profile: MovementProfile,
) -> NifResult<MovementState> {
    Ok(integrator::step(&state, &input_frame, &profile))
}

// replay:对 input_frames 做 O(N) 循环积分,回放窗口可较大、单次可能 >1ms → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn replay(
    anchor_state: MovementState,
    input_frames: Vec<InputFrame>,
    profile: MovementProfile,
) -> NifResult<Vec<MovementState>> {
    Ok(integrator::replay(&anchor_state, &input_frames, &profile))
}
