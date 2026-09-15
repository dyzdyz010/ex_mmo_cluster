//! 全局系统功能：不可变世界输入的批量热演化；不持有 canonical 状态。
use rustler::{Error, NifResult};

// 温度、HP、MaxHP、热容量、导热率、耐热阈值、暴露面数、功率、源余能、是否活动种子。
#[derive(rustler::NifTuple)]
struct Input(f64, f64, f64, f64, f64, f64, f64, f64, f64, bool);
type Output = (f64, f64, f64);

#[rustler::nif(schedule = "DirtyCpu")]
fn batch(input: Vec<Input>, edges: Vec<(usize, usize)>, ambient: f64, exchange: f64,
         tolerance: f64, dt: f64, steps: u32) -> NifResult<(u32, Vec<Output>, f64, f64)> {
    // 唯一 NIF 边界校验；内核仅消费有效索引和物性。
    if steps == 0 || !dt.is_finite() || dt <= 0.0 || !ambient.is_finite()
        || !exchange.is_finite() || exchange < 0.0 || !tolerance.is_finite() || tolerance < 0.0
        || input.iter().any(|n| [n.0,n.1,n.2,n.3,n.4,n.5,n.6,n.7,n.8].iter().any(|x| !x.is_finite())
            || n.3 <= 0.0 || n.5 <= 0.0 || n.4 < 0.0 || n.6 < 0.0 || n.7 < 0.0 || n.8 < 0.0)
        || edges.iter().any(|&(a,b)| a >= input.len() || b >= input.len() || a == b) {
        return Err(Error::BadArg);
    }
    Ok(evolve(&input, &edges, ambient, exchange, tolerance, dt, steps))
}

fn evolve(input: &[Input], edges: &[(usize,usize)], ambient: f64, exchange: f64,
          tolerance: f64, dt: f64, steps: u32) -> (u32, Vec<Output>, f64, f64) {
    let mut state: Vec<Output> = input.iter().map(|n| (n.0,n.1,n.8)).collect();
    let contacts: Vec<_> = edges.iter().map(|&(a,b)| {
        let ka=input[a].4; let kb=input[b].4;
        (a,b,if ka+kb==0.0 {0.0} else {2.0*ka*kb/(ka+kb)})
    }).collect();
    let mut flow=vec![0.0; input.len()];
    let (mut supplied,mut environment)=(0.0,0.0);
    for step in 1..=steps {
        flow.fill(0.0);
        for &(a,b,k) in &contacts {
            let q=k*(state[b].0-state[a].0)*dt;
            flow[a]+=q; flow[b]-=q;
        }
        let mut changed_support=false;
        for (i,n) in input.iter().enumerate() {
            let (temperature,hp,remaining)=state[i];
            let q=remaining.min(n.7*dt);
            let air=exchange*n.6*(ambient-temperature)*dt;
            let temperature=temperature+(flow[i]+q+air)/n.3;
            let hp=(hp-n.2*dt*(temperature/n.5-1.0).max(0.0)).max(0.0);
            let remaining=remaining-q;
            state[i]=(temperature,hp,remaining);
            supplied+=q; environment+=air;
            changed_support |= ((temperature-ambient).abs()>tolerance || remaining>0.0) != n.9;
        }
        // 活动前沿变化后交还 World：下一步必须重建真实六邻域，不能隔批才传播。
        if changed_support { return (step,state,supplied,environment); }
    }
    (steps,state,supplied,environment)
}

rustler::init!("Elixir.VoxelRegion.ThermalNative");
