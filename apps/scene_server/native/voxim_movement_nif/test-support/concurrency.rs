//! 仅测试构建使用：在实际 DirtyCpu 查询持有只读 world 后设置同步点。
use std::sync::{Arc, Barrier, Mutex};
use rustler::{Atom, Env, LocalPid};
rustler::atoms! { query_ready, ok }
static READERS: Mutex<Option<(LocalPid, Arc<Barrier>)>> = Mutex::new(None);

#[rustler::nif]
fn test_arm(env:Env<'_>) -> Atom {
    *READERS.lock().unwrap() = Some((env.pid(), Arc::new(Barrier::new(3))));
    ok()
}

pub fn meet(env:Env<'_>) {
    let pair = READERS.lock().unwrap().clone();
    if let Some((parent, barrier)) = pair {
        let _ = env.send(&parent, query_ready());
        barrier.wait();
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn test_release() -> Atom {
    let (_, barrier) = READERS.lock().unwrap().take().unwrap();
    barrier.wait();
    ok()
}
