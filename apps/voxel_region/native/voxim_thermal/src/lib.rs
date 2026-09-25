//! 全局系统功能：不可变世界输入的批量热演化；不持有 canonical 状态。
use rustler::{Error, NifResult};

// 温度、HP、MaxHP、热容量、导热率、耐热阈值、暴露面数、功率、源余能、是否活动种子。
#[derive(rustler::NifTuple)]
struct Input(f64, f64, f64, f64, f64, f64, f64, f64, f64, bool);
type Output = (f64, f64, f64);

// 斯特藩-玻尔兹曼常数，W/(m²·K⁴)（CODATA 2018 精确值）。
const SIGMA: f64 = 5.670374419e-8;

// 灰体辐射项：互见面半对 (a, b, 有效面积) 与对天空面 (节点, ε×面积)，发射率因子已由 World 乘入。
// 两个列表为空即无辐射，数值路径与引入辐射前逐位相同。
type Radiation = (Vec<(usize, usize, f64)>, Vec<(usize, f64)>);

// 焓、实际体积、相变温度、实际潜热总量、单位体积热容、是否液体；数值来自 World 的已发布目录。
#[derive(rustler::NifTuple)]
struct PhaseInput(f64, f64, f64, f64, f64, bool);

// 环境温度：全局标量，或逐节点（节点所在气候区，与节点同序同长）。
#[derive(rustler::NifUntaggedEnum)]
enum Ambient {
    Uniform(f64),
    PerNode(Vec<f64>),
}

#[derive(rustler::NifUntaggedEnum)]
enum AdvanceOutput {
    Numeric(Output),
    Phase((f64, f64, f64, f64)),
}

// 纯数值调用保持原元组；World 额外声明点燃阈值、相变回写和共享完整度结算边界。
#[derive(rustler::NifUntaggedEnum)]
enum AdvanceInput {
    Controlled((Input, (Option<f64>, Option<PhaseInput>, bool))),
    Numeric(Input),
}

#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
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
    let ambient=vec![ambient; input.len()];
    Ok(evolve(&input, &contacts, &(vec![], vec![]), &ambient, exchange, tolerance, dt, steps, true))
}

// 有限体积显式离散：dt <= C / (接触导热系数之和 + 环境换热系数 + 辐射线性化系数)，保留正系数。
// ambient 逐节点：节点所在气候区的空气温度（无气候区时全部等于全局环境，数值与标量版逐位相同）。
#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
fn advance(nodes: Vec<AdvanceInput>, contacts: Vec<(usize,usize,f64)>, ambient: Ambient, exchange: f64,
           tolerance: f64, duration: f64, radiation: Radiation) -> NifResult<(f64,Vec<AdvanceOutput>,f64,f64)> {
    let (input, events): (Vec<_>, Vec<_>) = nodes.into_iter().map(|node| match node {
        AdvanceInput::Controlled((input, events)) => (input, events),
        AdvanceInput::Numeric(input) => (input, (None, None, false)),
    }).unzip();
    let ambient = match ambient {
        Ambient::Uniform(a) => vec![a; input.len()],
        Ambient::PerNode(a) => a,
    };
    if !duration.is_finite() || duration <= 0.0 || ambient.len() != input.len()
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
                        || p.1<=0.0 || p.2<=0.0 || p.3<=0.0 || p.4<=0.0)) {
        return Err(Error::BadArg);
    }
    let mut diagonal: Vec<f64> = input.iter().map(|n| exchange*n.6).collect();
    for &(a,b,g) in &contacts { diagonal[a]+=g; diagonal[b]+=g; }
    let linear = stable_dt(&input,&diagonal);
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
            stable_dt(&input,&diagonal)
        } else { linear };
        let steps=(segment/stable).ceil() as u32;
        let dt=segment/f64::from(steps);
        let (count,q,air,mut frontier)=evolve_steps(&input,&contacts,&radiation,&ambient,exchange,tolerance,
            dt,steps,false,&mut state,&mut flow,&mut heat);
        let advanced=f64::from(count)*dt;
        done+=advanced; remaining-=advanced; supplied+=q; environment+=air;
        let mut phase_complete=false;
        for (((((s,(_,params,_)),phase),n),delta),a) in state.iter_mut().zip(&events).zip(&mut phases).zip(&input).zip(&heat).zip(&ambient) {
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
        let world_event=input.iter().zip(&state).zip(&events).any(|((n,s),(ignition,_,shared))| {
            ignition.is_some_and(|t| s.0>=t) || (*shared && s.1<n.1)
                || (n.1>0.0 && s.1==0.0)
        });
        // 与 World 剩余时长终止条件相同；跨系统事件不在 NIF 写回 canonical 真值。
        if frontier || phase_complete || world_event || remaining<1.0e-12 {
            let elapsed=if remaining<1.0e-12 { duration } else { done };
            let output=state.into_iter().zip(phases).map(|(s,p)| match p {
                Some(energy)=>AdvanceOutput::Phase((s.0,s.1,s.2,energy)),
                None=>AdvanceOutput::Numeric(s),
            }).collect();
            return Ok((elapsed,output,supplied,environment));
        }
    }
}

fn stable_dt(input: &[Input], diagonal: &[f64]) -> f64 {
    input.iter().zip(diagonal).filter(|(_,g)| **g>0.0)
        .map(|(n,g)| 0.45*n.3/g).fold(0.05_f64,f64::min)
}

fn evolve(input: &[Input], contacts: &[(usize,usize,f64)], radiation: &Radiation, ambient: &[f64], exchange: f64,
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

#[cfg(not(test))]
rustler::init!("Elixir.VoxelRegion.ThermalNative");

#[cfg(test)]
mod tests {
    use super::*;

    // 只测试：真实冰物性、有限源，解析能源为功率乘277秒；不依赖World或历史状态。
    #[test]
    fn latent_heat_uses_finite_source_energy_without_temperature_roundtrip_drift() {
        let initial = 65_279_273.67109645;
        let mut energy = initial;
        let mut delivered = 0.0;
        for _ in 0..554 {
            let node = AdvanceInput::Controlled((
                Input(273.15, 100.0, 100.0, 1_930_000.0, 2.2, 1_000_000.0,
                      0.0, 575.2, 287.6, true),
                (None, Some(PhaseInput(energy, 1.0, 273.15, 334_000_000.0,
                                      1_930_000.0, false)), false),
            ));
            let (done, out, q, air) = advance(vec![node], vec![], Ambient::PerNode(vec![293.15]), 0.0, 0.01, 0.5, (vec![], vec![])).unwrap();
            assert_eq!(done, 0.5);
            match out[0] {
                AdvanceOutput::Phase((temperature, _, _, next)) => {
                    assert_eq!(temperature, 273.15);
                    energy = next;
                }
                _ => panic!("相变节点必须返回焓"),
            }
            delivered += q + air;
        }
        let expected = 575.2 * 277.0;
        assert!((delivered - expected).abs() < 1.0e-4);
        let residual = energy - initial - expected;
        println!("latent_source_residual_j={residual}");
        assert!(residual.abs() < 1.0e-4, "焓残差 {residual} J");
    }

    // 只测试：接触热量在两相态间搬运，外界账覆盖源与环境；小热容节点触发多子步。
    #[test]
    fn phase_contacts_and_environment_share_the_same_substep_heat() {
        let ice_energy = 65_000_000.0;
        let water_energy = 334_000_000.0 + 4_180_000.0 * 10.0;
        let phase_node = |temperature, capacity, energy, liquid| AdvanceInput::Controlled((
            Input(temperature, 100.0, 100.0, capacity, 2.2, 1_000_000.0,
                  1.0, 20.0, 10.0, true),
            (None, Some(PhaseInput(energy, 1.0, 273.15, 334_000_000.0, capacity, liquid)), false),
        ));
        let nodes = vec![
            phase_node(273.15, 1_930_000.0, ice_energy, false),
            phase_node(283.15, 4_180_000.0, water_energy, true),
            AdvanceInput::Numeric(Input(293.15, 1.0, 1.0, 0.1, 1.0, 1_000_000.0,
                                        1.0, 0.0, 0.0, true)),
        ];
        let (done, out, supplied, environment) =
            advance(nodes, vec![(0, 1, 100.0)], Ambient::Uniform(293.15), 10.0, 0.01, 0.5, (vec![], vec![])).unwrap();
        assert_eq!(done, 0.5);
        let mut delta = 0.0;
        for (index, initial) in [ice_energy, water_energy].into_iter().enumerate() {
            match out[index] {
                AdvanceOutput::Phase((_, _, _, energy)) => delta += energy - initial,
                _ => panic!("相变节点必须返回焓"),
            }
        }
        match out[2] {
            AdvanceOutput::Numeric((temperature, _, _)) => delta += 0.1 * (temperature - 293.15),
            _ => panic!("普通节点不能返回相变焓"),
        }
        assert!((delta - supplied - environment).abs() < 1.0e-4);
        assert!((supplied - 20.0).abs() < 1.0e-10);
    }

    // 只测试：共享演化函数仍按有限源预算更新普通节点，期望来自Q=CΔT。
    #[test]
    fn numeric_batch_preserves_finite_source_contract() {
        let node = Input(293.15, 1.0, 1.0, 10.0, 1.0, 1_000_000.0, 0.0, 2.0, 0.3, true);
        let (done, out, supplied, environment) =
            batch(vec![node], vec![], 293.15, 0.0, 0.01, 0.1, 5).unwrap();
        assert_eq!(done, 5);
        assert!((out[0].0 - 293.18).abs() < 1.0e-12);
        assert_eq!(out[0].2, 0.0);
        assert!((supplied - 0.3).abs() < 1.0e-12);
        assert_eq!(environment, 0.0);
    }
}
