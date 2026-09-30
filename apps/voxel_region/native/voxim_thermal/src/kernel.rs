//! 全局系统功能：纯数值热演化内核——有限体积显式离散、灰体辐射、相变焓与事件边界；不持有任何状态。

// 温度、HP、MaxHP、热容量、导热率、耐热阈值、暴露面数、功率、源余能、是否活动种子。
#[derive(rustler::NifTuple, Clone, Copy)]
pub struct Input(pub f64, pub f64, pub f64, pub f64, pub f64, pub f64, pub f64, pub f64, pub f64, pub bool);
pub type Output = (f64, f64, f64);

// 斯特藩-玻尔兹曼常数，W/(m²·K⁴)（CODATA 2018 精确值）。
const SIGMA: f64 = 5.670374419e-8;

// 灰体辐射项：互见面半对 (a, b, 有效面积) 与对天空面 (节点, ε×面积)，发射率因子已由 World 乘入。
// 两个列表为空即无辐射，数值路径与引入辐射前逐位相同。
pub type Radiation = (Vec<(usize, usize, f64)>, Vec<(usize, f64)>);

// 焓、实际体积、相变温度、实际潜热总量、单位体积热容、是否液体；数值来自 World 的已发布目录。
#[derive(rustler::NifTuple, Clone, Copy)]
pub struct PhaseInput(pub f64, pub f64, pub f64, pub f64, pub f64, pub bool);

// 点燃阈值、相变参数、共享完整度结算边界。
pub type Events = (Option<f64>, Option<PhaseInput>, bool);

/// 一次演进的结果：实际时长、逐节点 (温度, HP, 余能)、相变节点的焓、供能与环境交换。
pub struct Outcome {
    pub elapsed: f64,
    pub state: Vec<Output>,
    pub phases: Vec<Option<f64>>,
    pub supplied: f64,
    pub environment: f64,
}

/// 唯一 NIF 边界校验；内核仅消费有效索引和物性。
pub fn valid(input: &[Input], events: &[Events], contacts: &[(usize, usize, f64)], ambient: &[f64], exchange: f64,
             tolerance: f64, duration: f64, radiation: &Radiation) -> bool {
    !(!duration.is_finite() || duration <= 0.0 || ambient.len() != input.len()
        || ambient.iter().any(|a| !a.is_finite())
        || !exchange.is_finite() || exchange < 0.0 || !tolerance.is_finite() || tolerance < 0.0
        || input.iter().any(|n| [n.0,n.1,n.2,n.3,n.4,n.5,n.6,n.7,n.8].iter().any(|v| !v.is_finite())
            || n.3<=0.0 || n.5<=0.0 || n.6<0.0 || n.8<0.0)
        || contacts.iter().chain(&radiation.0).any(|&(a,b,g)| a>=input.len() || b>=input.len() || a==b || !g.is_finite() || g<0.0)
        || radiation.1.iter().any(|&(i,s)| i>=input.len() || !s.is_finite() || s<0.0)
        || events.iter().any(|(ignition,phase,_)|
            ignition.is_some_and(|t| !t.is_finite() || t<=0.0)
                || phase.as_ref().is_some_and(|p|
                    [p.0,p.1,p.2,p.3,p.4].iter().any(|v| !v.is_finite())
                        || p.1<=0.0 || p.2<=0.0 || p.3<=0.0 || p.4<=0.0)))
}

/// 有限体积显式离散：dt <= C / (接触导热系数之和 + 环境换热系数 + 辐射线性化系数)，保留正系数。
/// ambient 逐节点：节点所在气候区的空气温度（无气候区时全部等于全局环境，数值与标量版逐位相同）。
/// 按 50 ms 分段推进到时长用完，或新热前沿、相变完成、点燃及共享 HP 事件时提前返回。
pub fn advance(input: &[Input], events: &[Events], contacts: &[(usize, usize, f64)], ambient: &[f64], exchange: f64,
               tolerance: f64, duration: f64, radiation: &Radiation) -> Outcome {
    let mut diagonal: Vec<f64> = input.iter().map(|n| exchange*n.6).collect();
    for &(a,b,g) in contacts { diagonal[a]+=g; diagonal[b]+=g; }
    let linear = stable_dt(input,&diagonal);
    let radiating = !radiation.0.is_empty() || !radiation.1.is_empty();
    let mut state: Vec<Output> = input.iter().map(|n| (n.0,n.1,n.8)).collect();
    let mut flow=vec![0.0; input.len()];
    let mut heat=vec![0.0; input.len()];
    let mut phases: Vec<_> = events.iter().map(|(_,p,_)| p.as_ref().map(|p| p.0)).collect();
    let (mut remaining,mut done,mut supplied,mut environment)=(duration,0.0,0.0,0.0);
    loop {
        // 保留 World 原有的 50ms 分段及每段 ceil/dt 算术，不把整批重新均分。
        let segment=remaining.min(0.05);
        // T⁴ 项按段首温度线性化 4σwT³ 重算稳定步长；无辐射时沿用原一次性步长。
        let stable=if radiating {
            let mut diagonal=diagonal.clone();
            for &(a,b,w) in &radiation.0 {
                let h=4.0*SIGMA*w*state[a].0.max(state[b].0).powi(3);
                diagonal[a]+=h; diagonal[b]+=h;
            }
            for &(i,s) in &radiation.1 { diagonal[i]+=4.0*SIGMA*s*state[i].0.powi(3); }
            stable_dt(input,&diagonal)
        } else { linear };
        let steps=(segment/stable).ceil() as u32;
        let dt=segment/f64::from(steps);
        let (count,q,air,mut frontier)=evolve_steps(input,contacts,radiation,ambient,exchange,tolerance,
            dt,steps,false,&mut state,&mut flow,&mut heat);
        let advanced=f64::from(count)*dt;
        done+=advanced; remaining-=advanced; supplied+=q; environment+=air;
        let mut phase_complete=false;
        for (((((s,(_,params,_)),phase),n),delta),a) in state.iter_mut().zip(events).zip(&mut phases).zip(input).zip(&heat).zip(ambient) {
            if let (Some(p),Some(energy))=(params.as_ref(),phase.as_mut()) {
                let before=*energy;
                // 焓直接接收同一段的净热量，避免从已舍入的温差逆推能量。
                *energy+=delta;
                let sensible=if p.5 { (*energy-p.3).max(0.0) } else { energy.min(0.0) };
                s.0=p.2+sensible/(p.1*p.4);
                // 原 World 在焓回写后也会激活新热格；首次初始化的相变几何不能延迟扩域。
                frontier |= !n.9 && ((s.0-a).abs()>tolerance || s.2>0.0);
                // 只在完成条件首次跨越时通知；材质替换仍由 World 的既有提交规则负责。
                phase_complete |= if p.5 { before>0.0 && *energy<=0.0 }
                    else { before<p.3 && *energy>=p.3 };
            }
        }
        let world_event=input.iter().zip(&state).zip(events).any(|((n,s),(ignition,_,shared))| {
            ignition.is_some_and(|t| s.0>=t) || (*shared && s.1<n.1)
                || (n.1>0.0 && s.1==0.0)
        });
        // 与 World 剩余时长终止条件相同；跨系统事件不在 NIF 写回 canonical 真值。
        if frontier || phase_complete || world_event || remaining<1.0e-12 {
            let elapsed=if remaining<1.0e-12 { duration } else { done };
            return Outcome { elapsed, state, phases, supplied, environment };
        }
    }
}

fn stable_dt(input: &[Input], diagonal: &[f64]) -> f64 {
    input.iter().zip(diagonal).filter(|(_,g)| **g>0.0)
        .map(|(n,g)| 0.45*n.3/g).fold(0.05_f64,f64::min)
}

pub fn evolve(input: &[Input], contacts: &[(usize,usize,f64)], radiation: &Radiation, ambient: &[f64], exchange: f64,
              tolerance: f64, dt: f64, steps: u32, return_on_cooling: bool) -> (u32, Vec<Output>, f64, f64) {
    let mut state: Vec<Output> = input.iter().map(|n| (n.0,n.1,n.8)).collect();
    let mut flow=vec![0.0; input.len()];
    let mut heat=vec![0.0; input.len()];
    let (done,supplied,environment,_)=evolve_steps(input,contacts,radiation,ambient,exchange,tolerance,
        dt,steps,return_on_cooling,&mut state,&mut flow,&mut heat);
    (done,state,supplied,environment)
}

fn evolve_steps(input: &[Input], contacts: &[(usize,usize,f64)], radiation: &Radiation, ambient: &[f64], exchange: f64,
          tolerance: f64, dt: f64, steps: u32, return_on_cooling: bool,
          state: &mut [Output], flow: &mut [f64], heat: &mut [f64]) -> (u32, f64, f64, bool) {
    let (mut supplied,mut environment)=(0.0,0.0);
    heat.fill(0.0);
    for step in 1..=steps {
        flow.fill(0.0);
        for &(a,b,k) in contacts {
            let q=k*(state[b].0-state[a].0)*dt;
            flow[a]+=q; flow[b]-=q;
        }
        // 互见面对反对称交换，能量守恒；对天空面换热与线性环境换热同记环境账。
        for &(a,b,w) in &radiation.0 {
            let q=SIGMA*w*(state[b].0.powi(4)-state[a].0.powi(4))*dt;
            flow[a]+=q; flow[b]-=q;
        }
        for &(i,s) in &radiation.1 {
            let q=SIGMA*s*(ambient[i].powi(4)-state[i].0.powi(4))*dt;
            flow[i]+=q; environment+=q;
        }
        let mut changed_support=false;
        for (i,n) in input.iter().enumerate() {
            let (temperature,hp,remaining)=state[i];
            let used=remaining.min(n.7.abs()*dt);
            let q=used*n.7.signum();
            let air=exchange*n.6*(ambient[i]-temperature)*dt;
            let delta=flow[i]+q+air;
            let temperature=temperature+delta/n.3;
            heat[i]+=delta;
            let hp=(hp-n.2*dt*(temperature/n.5-1.0).max(0.0)).max(0.0);
            let remaining=remaining-used;
            state[i]=(temperature,hp,remaining);
            supplied+=q; environment+=air;
            let active=(temperature-ambient[i]).abs()>tolerance || remaining>0.0;
            changed_support |= if return_on_cooling { active != n.9 } else { active && !n.9 };
        }
        // 新热前沿立即交还 World 扩张六邻域；advance 的冷却域在提交批末统一收缩。
        if changed_support { return (step,supplied,environment,true); }
    }
    (steps,supplied,environment,false)
}
