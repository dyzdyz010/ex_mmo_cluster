//! 全局系统功能：不可变世界输入的批量热演化；不持有 canonical 状态。
use rustler::{Error, NifResult};

// 温度、HP、MaxHP、热容量、导热率、耐热阈值、暴露面数、功率、源余能、是否活动种子。
#[derive(rustler::NifTuple)]
struct Input(f64, f64, f64, f64, f64, f64, f64, f64, f64, bool);
type Output = (f64, f64, f64);

// 纯数值调用保持原元组；World 额外声明点燃阈值、相变回写和共享完整度结算边界。
#[derive(rustler::NifUntaggedEnum)]
enum AdvanceInput {
    Controlled((Input, (Option<f64>, Option<(f64, bool)>, bool))),
    Numeric(Input),
}

#[rustler::nif(schedule = "DirtyCpu")]
fn batch(input: Vec<Input>, edges: Vec<(usize, usize)>, ambient: f64, exchange: f64,
         tolerance: f64, dt: f64, steps: u32) -> NifResult<(u32, Vec<Output>, f64, f64)> {
    // 唯一 NIF 边界校验；内核仅消费有效索引和物性。
    if steps == 0 || !dt.is_finite() || dt <= 0.0 || !ambient.is_finite()
        || !exchange.is_finite() || exchange < 0.0 || !tolerance.is_finite() || tolerance < 0.0
        || input.iter().any(|n| [n.0,n.1,n.2,n.3,n.4,n.5,n.6,n.7,n.8].iter().any(|x| !x.is_finite())
            || n.3 <= 0.0 || n.5 <= 0.0 || n.4 < 0.0 || n.6 < 0.0 || n.8 < 0.0)
        || edges.iter().any(|&(a,b)| a >= input.len() || b >= input.len() || a == b) {
        return Err(Error::BadArg);
    }
    let contacts: Vec<_> = edges.iter().map(|&(a,b)| {
        let ka=input[a].4; let kb=input[b].4;
        (a,b,if ka+kb==0.0 {0.0} else {2.0*ka*kb/(ka+kb)})
    }).collect();
    Ok(evolve(&input, &contacts, ambient, exchange, tolerance, dt, steps, true))
}

// 有限体积显式离散：dt <= C / (接触导热系数之和 + 环境换热系数)，保留正系数。
#[rustler::nif(schedule = "DirtyCpu")]
fn advance(nodes: Vec<AdvanceInput>, contacts: Vec<(usize,usize,f64)>, ambient: f64, exchange: f64,
           tolerance: f64, duration: f64) -> NifResult<(f64,Vec<Output>,f64,f64)> {
    let (input, events): (Vec<_>, Vec<_>) = nodes.into_iter().map(|node| match node {
        AdvanceInput::Controlled((input, events)) => (input, events),
        AdvanceInput::Numeric(input) => (input, (None, None, false)),
    }).unzip();
    if !duration.is_finite() || duration <= 0.0 || !ambient.is_finite()
        || !exchange.is_finite() || exchange < 0.0 || !tolerance.is_finite() || tolerance < 0.0
        || input.iter().any(|n| [n.0,n.1,n.2,n.3,n.4,n.5,n.6,n.7,n.8].iter().any(|v| !v.is_finite())
            || n.3<=0.0 || n.5<=0.0 || n.6<0.0 || n.8<0.0)
        || contacts.iter().any(|&(a,b,g)| a>=input.len() || b>=input.len() || a==b || !g.is_finite() || g<0.0)
        || events.iter().any(|(ignition,phase,_)|
            ignition.is_some_and(|t| !t.is_finite() || t<=0.0)
                || phase.is_some_and(|(t,_)| !t.is_finite() || t<=0.0)) {
        return Err(Error::BadArg);
    }
    let mut diagonal: Vec<f64> = input.iter().map(|n| exchange*n.6).collect();
    for &(a,b,g) in &contacts { diagonal[a]+=g; diagonal[b]+=g; }
    let stable = input.iter().zip(&diagonal).filter(|(_,g)| **g>0.0)
        .map(|(n,g)| 0.45*n.3/g).fold(0.05_f64,f64::min);
    let mut state: Vec<Output> = input.iter().map(|n| (n.0,n.1,n.8)).collect();
    let mut flow=vec![0.0; input.len()];
    let (mut remaining,mut done,mut supplied,mut environment)=(duration,0.0,0.0,0.0);
    loop {
        // 保留 World 原有的 50ms 分段及每段 ceil/dt 算术，不把整批重新均分。
        let segment=remaining.min(0.05);
        let steps=(segment/stable).ceil() as u32;
        let dt=segment/f64::from(steps);
        let (count,q,air,frontier)=evolve_steps(&input,&contacts,ambient,exchange,tolerance,
            dt,steps,false,&mut state,&mut flow);
        let advanced=f64::from(count)*dt;
        done+=advanced; remaining-=advanced; supplied+=q; environment+=air;
        let world_event=input.iter().zip(&state).zip(&events).any(|((n,s),(ignition,phase,shared))| {
            // Phase.temperature 在线性显热区不钳位；潜热区及进入该区的段必须由 World 回写焓。
            let phase_event=phase.is_some_and(|(t,liquid)|
                if liquid { n.0<=t || s.0<=t } else { n.0>=t || s.0>=t });
            phase_event || ignition.is_some_and(|t| s.0>=t) || (*shared && s.1<n.1)
                || (n.1>0.0 && s.1==0.0)
        });
        // 与 World 剩余时长终止条件相同；跨系统事件不在 NIF 写回 canonical 真值。
        if frontier || world_event || remaining<1.0e-12 {
            let elapsed=if remaining<1.0e-12 { duration } else { done };
            return Ok((elapsed,state,supplied,environment));
        }
    }
}

fn evolve(input: &[Input], contacts: &[(usize,usize,f64)], ambient: f64, exchange: f64,
          tolerance: f64, dt: f64, steps: u32, return_on_cooling: bool) -> (u32, Vec<Output>, f64, f64) {
    let mut state: Vec<Output> = input.iter().map(|n| (n.0,n.1,n.8)).collect();
    let mut flow=vec![0.0; input.len()];
    let (done,supplied,environment,_)=evolve_steps(input,contacts,ambient,exchange,tolerance,
        dt,steps,return_on_cooling,&mut state,&mut flow);
    (done,state,supplied,environment)
}

fn evolve_steps(input: &[Input], contacts: &[(usize,usize,f64)], ambient: f64, exchange: f64,
          tolerance: f64, dt: f64, steps: u32, return_on_cooling: bool,
          state: &mut [Output], flow: &mut [f64]) -> (u32, f64, f64, bool) {
    let (mut supplied,mut environment)=(0.0,0.0);
    for step in 1..=steps {
        flow.fill(0.0);
        for &(a,b,k) in contacts {
            let q=k*(state[b].0-state[a].0)*dt;
            flow[a]+=q; flow[b]-=q;
        }
        let mut changed_support=false;
        for (i,n) in input.iter().enumerate() {
            let (temperature,hp,remaining)=state[i];
            let used=remaining.min(n.7.abs()*dt);
            let q=used*n.7.signum();
            let air=exchange*n.6*(ambient-temperature)*dt;
            let temperature=temperature+(flow[i]+q+air)/n.3;
            let hp=(hp-n.2*dt*(temperature/n.5-1.0).max(0.0)).max(0.0);
            let remaining=remaining-used;
            state[i]=(temperature,hp,remaining);
            supplied+=q; environment+=air;
            let active=(temperature-ambient).abs()>tolerance || remaining>0.0;
            changed_support |= if return_on_cooling { active != n.9 } else { active && !n.9 };
        }
        // 新热前沿立即交还 World 扩张六邻域；advance 的冷却域在提交批末统一收缩。
        if changed_support { return (step,supplied,environment,true); }
    }
    (steps,supplied,environment,false)
}

rustler::init!("Elixir.VoxelRegion.ThermalNative");
