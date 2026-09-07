//! 服务端 M0 离线实验入口；直接执行共享内核，不接入旧 PlayerCharacter 或网络 tick。
use voxim_movement::experiment::{Fixture,replay};
fn main() {
    let args:Vec<_>=std::env::args().collect();
    assert_eq!(args.len(),3,"用法：voxim_m0 <suite.json> <输出目录>");
    let fixture:Fixture=serde_json::from_slice(&std::fs::read(&args[1]).expect("读取实验夹具")).expect("解析实验夹具");
    replay(&fixture,std::path::Path::new(&args[2])).expect("写入实验结果");
    println!("M0 replay complete: {} scenarios; 30/60 Hz; compound/voxels",fixture.scenarios.len());
}
