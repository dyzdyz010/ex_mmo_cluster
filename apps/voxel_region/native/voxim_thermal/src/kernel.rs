//! 全局系统功能：纯数值热演化内核——有限体积显式离散、灰体辐射、相变焓与事件边界；不持有任何状态。
//!
//! 外部节点（魔法结构的热端口）可带限流参数 [`Limit`]：每个子步先按现有公式算出全部热流（只算不施加），
//! 再按吞吐上限等比缩放、按温度上下限钳制，最后统一施加（设计 §5.3.1）。不带参数的节点即"不限"，
//! 全部节点不限时每项系数都是 1.0，数值与引入限流前逐位相同。

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

/// 节点限流参数 {吞吐上限 Φ（W）, 温度下限 t_lo（K）, 温度上限 t_hi（K）}（设计 §5.3.1、§4.4）。
///
/// 吞吐：每个子步与本节点相关的四类热流（接触、互见辐射、对天空辐射、对流）传递能量的绝对值之和不超过 Φ·dt；
/// 温度：施加后节点温度不越过 [t_lo, t_hi]。由 World 在每次调用前按结构的容量与储能算出；
/// 不受限的节点不带此参数（等价于 Φ = +∞、t_lo = −∞、t_hi = +∞，Erlang 浮点没有无穷，所以用"缺省"表达）。
#[derive(rustler::NifTuple, Clone, Copy, Debug, PartialEq)]
pub struct Limit(pub f64, pub f64, pub f64);

/// 一次调用的内核计数（可观测面：`voxel_thermal_throttle`、切片 8 的 `kernel_steps`）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Counters {
    /// 实际执行的子步数（全部 50 ms 段之和）。
    pub steps: u32,
    /// 至少有一个子步吞吐缩放比 s < 1 的受限节点数。
    pub throttled: u32,
    /// 至少有一个子步被温度钳制（k < 1）的受限节点数。
    pub clamped: u32,
    /// 本次调用中最小的吞吐缩放比 s；没有发生吞吐缩放时为 1.0。
    pub min_scale: f64,
}

impl Default for Counters {
    fn default() -> Self {
        Counters { steps: 0, throttled: 0, clamped: 0, min_scale: 1.0 }
    }
}

/// 一次演进的结果：实际时长、逐节点 (温度, HP, 余能)、相变节点的焓、供能与环境交换、内核计数。
pub struct Outcome {
    pub elapsed: f64,
    pub state: Vec<Output>,
    pub phases: Vec<Option<f64>>,
    pub supplied: f64,
    pub environment: f64,
    pub counters: Counters,
}

/// 唯一 NIF 边界校验；内核仅消费有效索引和物性。`limits` 为空表示全部不限，否则与节点同序同长。
#[allow(clippy::too_many_arguments)]
pub fn valid(input: &[Input], events: &[Events], limits: &[Option<Limit>], contacts: &[(usize, usize, f64)],
             ambient: &[f64], exchange: f64, tolerance: f64, duration: f64, radiation: &Radiation) -> bool {
    !(!duration.is_finite() || duration <= 0.0 || ambient.len() != input.len()
        || ambient.iter().any(|a| !a.is_finite())
        || !exchange.is_finite() || exchange < 0.0 || !tolerance.is_finite() || tolerance < 0.0
        || input.iter().any(|n| [n.0,n.1,n.2,n.3,n.4,n.5,n.6,n.7,n.8].iter().any(|v| !v.is_finite())
            || n.3<=0.0 || n.5<=0.0 || n.6<0.0 || n.8<0.0)
        || contacts.iter().chain(&radiation.0).any(|&(a,b,g)| a>=input.len() || b>=input.len() || a==b || !g.is_finite() || g<0.0)
        || radiation.1.iter().any(|&(i,s)| i>=input.len() || !s.is_finite() || s<0.0)
        || !(limits.is_empty() || limits.len() == input.len())
        || limits.iter().flatten().any(|l| !l.0.is_finite() || !l.1.is_finite() || !l.2.is_finite()
            || l.0 < 0.0 || l.1 > l.2)
        || events.iter().any(|(ignition,phase,_)|
            ignition.is_some_and(|t| !t.is_finite() || t<=0.0)
                || phase.as_ref().is_some_and(|p|
                    [p.0,p.1,p.2,p.3,p.4].iter().any(|v| !v.is_finite())
                        || p.1<=0.0 || p.2<=0.0 || p.3<=0.0 || p.4<=0.0)))
}

/// 有限体积显式离散：dt <= C / (接触导热系数之和 + 环境换热系数 + 辐射线性化系数)，保留正系数。
/// ambient 逐节点：节点所在气候区的空气温度（无气候区时全部等于全局环境，数值与标量版逐位相同）。
/// 按 50 ms 分段推进到时长用完，或新热前沿、相变完成、点燃及共享 HP 事件时提前返回。
/// 限流只缩小热流，不改变稳定步长的计算（设计 §5.3.1"稳定性"）。
#[allow(clippy::too_many_arguments)]
pub fn advance(input: &[Input], events: &[Events], limits: &[Option<Limit>], contacts: &[(usize, usize, f64)],
               ambient: &[f64], exchange: f64, tolerance: f64, duration: f64, radiation: &Radiation) -> Outcome {
    let mut diagonal: Vec<f64> = input.iter().map(|n| exchange*n.6).collect();
    for &(a,b,g) in contacts { diagonal[a]+=g; diagonal[b]+=g; }
    let linear = stable_dt(input,&diagonal);
    let radiating = !radiation.0.is_empty() || !radiation.1.is_empty();
    let mut state: Vec<Output> = input.iter().map(|n| (n.0,n.1,n.8)).collect();
    let mut work = Work::new(input, limits, contacts, radiation);
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
            dt,steps,false,&mut state,&mut work);
        let advanced=f64::from(count)*dt;
        done+=advanced; remaining-=advanced; supplied+=q; environment+=air;
        let mut phase_complete=false;
        for (((((s,(_,params,_)),phase),n),delta),a) in state.iter_mut().zip(events).zip(&mut phases).zip(input).zip(&work.heat).zip(ambient) {
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
            let counters=work.counters();
            return Outcome { elapsed, state, phases, supplied, environment, counters };
        }
    }
}

fn stable_dt(input: &[Input], diagonal: &[f64]) -> f64 {
    input.iter().zip(diagonal).filter(|(_,g)| **g>0.0)
        .map(|(n,g)| 0.45*n.3/g).fold(0.05_f64,f64::min)
}

/// 旧 `batch/7` 接口的定步长演化（不带限流参数）。
#[allow(clippy::too_many_arguments)]
pub fn evolve(input: &[Input], contacts: &[(usize,usize,f64)], radiation: &Radiation, ambient: &[f64], exchange: f64,
              tolerance: f64, dt: f64, steps: u32, return_on_cooling: bool) -> (u32, Vec<Output>, f64, f64) {
    let mut state: Vec<Output> = input.iter().map(|n| (n.0,n.1,n.8)).collect();
    let mut work = Work::new(input, &[], contacts, radiation);
    let (done,supplied,environment,_)=evolve_steps(input,contacts,radiation,ambient,exchange,tolerance,
        dt,steps,return_on_cooling,&mut state,&mut work);
    (done,state,supplied,environment)
}

/// 一次调用内复用的工作区：本段逐节点净热、每个子步算出的各项热流与它们的施加系数，以及限流状态。
struct Work {
    flow: Vec<f64>,
    /// 本段（一次 `evolve_steps`）逐节点累计的净热量，供相变焓回写。
    heat: Vec<f64>,
    /// 本子步各项热流传递的能量（J）：接触边、互见半对、对天空面按各自列表下标，对流按节点下标；
    /// 符号与施加方向一致——接触与半对为"流向 a 端为正"，对天空与对流为"流向节点为正"。
    contact: Vec<f64>,
    pair: Vec<f64>,
    sky: Vec<f64>,
    air: Vec<f64>,
    /// 各项的施加系数；不触及受限节点的项恒为 1.0（乘 1.0 逐位不变）。
    contact_factor: Vec<f64>,
    pair_factor: Vec<f64>,
    sky_factor: Vec<f64>,
    air_factor: Vec<f64>,
    throttle: Option<Throttle>,
    steps: u32,
}

/// 受限节点与触及它们的项：拓扑在一次调用内不变，所以只在调用开始时收集一次。
struct Throttle {
    /// 受限节点下标与参数，按下标升序。
    nodes: Vec<(usize, Limit)>,
    /// 节点是否受限（与节点同长）。
    limited: Vec<bool>,
    /// 至少一端受限的接触边、互见半对，以及受限节点的对天空面（各自列表下标）。
    contacts: Vec<usize>,
    pairs: Vec<usize>,
    sky: Vec<usize>,
    /// 逐节点（只读写受限节点）：本子步的吞吐缩放比 s、流入系数、流出系数，以及暂存的绝对值之和与流入、流出合计。
    scale: Vec<f64>,
    inflow: Vec<f64>,
    outflow: Vec<f64>,
    total: Vec<f64>,
    gain: Vec<f64>,
    loss: Vec<f64>,
    /// 计数：曾被吞吐缩放、曾被温度钳制的节点，以及最小缩放比。
    throttled: Vec<bool>,
    clamped: Vec<bool>,
    min_scale: f64,
}

impl Work {
    fn new(input: &[Input], limits: &[Option<Limit>], contacts: &[(usize,usize,f64)], radiation: &Radiation) -> Work {
        let n = input.len();
        let nodes: Vec<(usize, Limit)> = limits.iter().enumerate().filter_map(|(i, l)| l.map(|l| (i, l))).collect();
        let throttle = (!nodes.is_empty()).then(|| {
            let mut limited = vec![false; n];
            for &(i, _) in &nodes { limited[i] = true; }
            let touching = |a: usize, b: usize| limited[a] || limited[b];
            Throttle {
                contacts: contacts.iter().enumerate().filter(|(_, &(a,b,_))| touching(a, b)).map(|(e, _)| e).collect(),
                pairs: radiation.0.iter().enumerate().filter(|(_, &(a,b,_))| touching(a, b)).map(|(e, _)| e).collect(),
                sky: radiation.1.iter().enumerate().filter(|(_, &(i,_))| limited[i]).map(|(e, _)| e).collect(),
                nodes, limited,
                scale: vec![1.0; n], inflow: vec![1.0; n], outflow: vec![1.0; n],
                total: vec![0.0; n], gain: vec![0.0; n], loss: vec![0.0; n],
                throttled: vec![false; n], clamped: vec![false; n], min_scale: 1.0,
            }
        });
        Work {
            flow: vec![0.0; n], heat: vec![0.0; n],
            contact: vec![0.0; contacts.len()], pair: vec![0.0; radiation.0.len()],
            sky: vec![0.0; radiation.1.len()], air: vec![0.0; n],
            contact_factor: vec![1.0; contacts.len()], pair_factor: vec![1.0; radiation.0.len()],
            sky_factor: vec![1.0; radiation.1.len()], air_factor: vec![1.0; n],
            throttle, steps: 0,
        }
    }

    fn counters(&self) -> Counters {
        let count = |flags: &[bool]| flags.iter().filter(|&&f| f).count() as u32;
        match &self.throttle {
            Some(t) => Counters { steps: self.steps, throttled: count(&t.throttled), clamped: count(&t.clamped),
                                  min_scale: t.min_scale },
            None => Counters { steps: self.steps, ..Counters::default() },
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn evolve_steps(input: &[Input], contacts: &[(usize,usize,f64)], radiation: &Radiation, ambient: &[f64], exchange: f64,
          tolerance: f64, dt: f64, steps: u32, return_on_cooling: bool,
          state: &mut [Output], work: &mut Work) -> (u32, f64, f64, bool) {
    let (mut supplied,mut environment)=(0.0,0.0);
    work.heat.fill(0.0);
    for step in 1..=steps {
        work.steps+=1;
        // 1. 按现有公式算出各项热流（只算，不施加）；各式与引入限流前相同，温度都取子步开始时的值。
        for (q,&(a,b,k)) in work.contact.iter_mut().zip(contacts) { *q=k*(state[b].0-state[a].0)*dt; }
        for (q,&(a,b,w)) in work.pair.iter_mut().zip(&radiation.0) {
            *q=SIGMA*w*(state[b].0.powi(4)-state[a].0.powi(4))*dt;
        }
        for (q,&(i,s)) in work.sky.iter_mut().zip(&radiation.1) {
            *q=SIGMA*s*(ambient[i].powi(4)-state[i].0.powi(4))*dt;
        }
        for (i,n) in input.iter().enumerate() { work.air[i]=exchange*n.6*(ambient[i]-state[i].0)*dt; }
        // 2–4. 受限节点：吞吐缩放与温度钳制，结果写入各项系数。
        if let Some(throttle)=work.throttle.as_mut() {
            throttle.factors(input, contacts, radiation, state, dt, &work.contact, &work.pair, &work.sky, &work.air,
                &mut work.contact_factor, &mut work.pair_factor, &mut work.sky_factor, &mut work.air_factor);
        }
        // 5. 施加：缩放后的热流对两端等量施加，守恒不变。互见面对反对称交换；对天空面换热与线性环境换热同记环境账。
        let flow=&mut work.flow;
        flow.fill(0.0);
        for ((&(a,b,_),q),f) in contacts.iter().zip(&work.contact).zip(&work.contact_factor) {
            let q=q*f;
            flow[a]+=q; flow[b]-=q;
        }
        for ((&(a,b,_),q),f) in radiation.0.iter().zip(&work.pair).zip(&work.pair_factor) {
            let q=q*f;
            flow[a]+=q; flow[b]-=q;
        }
        for ((&(i,_),q),f) in radiation.1.iter().zip(&work.sky).zip(&work.sky_factor) {
            let q=q*f;
            flow[i]+=q; environment+=q;
        }
        let mut changed_support=false;
        for (i,n) in input.iter().enumerate() {
            let (temperature,hp,remaining)=state[i];
            let used=remaining.min(n.7.abs()*dt);
            let q=used*n.7.signum();
            let air=work.air[i]*work.air_factor[i];
            let delta=flow[i]+q+air;
            let temperature=temperature+delta/n.3;
            work.heat[i]+=delta;
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

impl Throttle {
    /// 一个子步的限流系数（设计 §5.3.1 第 2–4 步，骨架对照 Zalesak 1979 FCT 限制器：节点约束 → 边取两端较小者 → 守恒）。
    ///
    /// - 吞吐：s_i = min(1, Φ_i·dt / Σ|q|)，Σ 取与 i 相关的四类热流；接触边与互见半对取两端 s 的较小值（不受限端为 1），
    ///   对天空与对流取 s_i。
    /// - 温度钳制：按缩放后的热流（加上不受限流的有限源）试算节点温度，越过 t_hi 时把流入各项按同一比例 k 缩小、
    ///   越过 t_lo 时把流出各项按同一比例 k 缩小，使节点恰好到达边界；k 作用于边时对端同步缩小，两端都要钳制的边取较小的 k。
    #[allow(clippy::too_many_arguments)]
    fn factors(&mut self, input: &[Input], contacts: &[(usize,usize,f64)], radiation: &Radiation, state: &[Output],
               dt: f64, contact: &[f64], pair: &[f64], sky: &[f64], air: &[f64],
               contact_factor: &mut [f64], pair_factor: &mut [f64], sky_factor: &mut [f64], air_factor: &mut [f64]) {
        // 2. 吞吐缩放：先累计每个受限节点相关热流的绝对值之和。
        for &(i, _) in &self.nodes { self.total[i]=air[i].abs(); }
        for &e in &self.contacts {
            let (a,b,_)=contacts[e];
            book_both(&mut self.total, &self.limited, a, b, contact[e].abs());
        }
        for &e in &self.pairs {
            let (a,b,_)=radiation.0[e];
            book_both(&mut self.total, &self.limited, a, b, pair[e].abs());
        }
        for &e in &self.sky { self.total[radiation.1[e].0]+=sky[e].abs(); }
        for &(i, Limit(phi, _, _)) in &self.nodes {
            let budget=phi*dt;
            let s=if budget<self.total[i] { budget/self.total[i] } else { 1.0 };
            self.scale[i]=s;
            if s<1.0 { self.throttled[i]=true; self.min_scale=self.min_scale.min(s); }
        }
        // 3. 各项的吞吐系数；同时按缩放后的热流累计每个受限节点的流入与流出。
        for &(i, _) in &self.nodes { (self.gain[i], self.loss[i])=(0.0, 0.0); }
        for &e in &self.contacts {
            let (a,b,_)=contacts[e];
            contact_factor[e]=self.edge_scale(a, b);
            let q=contact[e]*contact_factor[e];
            book_flow(&mut self.gain, &mut self.loss, &self.limited, a, b, q);
        }
        for &e in &self.pairs {
            let (a,b,_)=radiation.0[e];
            pair_factor[e]=self.edge_scale(a, b);
            let q=pair[e]*pair_factor[e];
            book_flow(&mut self.gain, &mut self.loss, &self.limited, a, b, q);
        }
        for &e in &self.sky {
            let i=radiation.1[e].0;
            sky_factor[e]=self.scale[i];
            book_signed(&mut self.gain, &mut self.loss, i, sky[e]*sky_factor[e]);
        }
        for &(i, _) in &self.nodes {
            air_factor[i]=self.scale[i];
            book_signed(&mut self.gain, &mut self.loss, i, air[i]*air_factor[i]);
        }
        // 4. 温度钳制：k 使试算温度恰好落在边界上；有限源不属于四类热流，按原样计入。
        for &(i, Limit(_, low, high)) in &self.nodes {
            let n=&input[i];
            let (temperature,_,remaining)=state[i];
            let source=remaining.min(n.7.abs()*dt)*n.7.signum();
            let (gain,loss)=(self.gain[i], self.loss[i]);
            let trial=temperature+(gain+loss+source)/n.3;
            let (mut inflow,mut outflow)=(1.0, 1.0);
            if trial>high && gain>0.0 {
                inflow=(((high-temperature)*n.3-loss-source)/gain).clamp(0.0, 1.0);
            } else if trial<low && loss<0.0 {
                outflow=(((low-temperature)*n.3-gain-source)/loss).clamp(0.0, 1.0);
            }
            (self.inflow[i], self.outflow[i])=(inflow, outflow);
            if inflow<1.0 || outflow<1.0 { self.clamped[i]=true; }
        }
        for &e in &self.contacts {
            let (a,b,_)=contacts[e];
            contact_factor[e]*=self.edge_clamp(a, b, contact[e]);
        }
        for &e in &self.pairs {
            let (a,b,_)=radiation.0[e];
            pair_factor[e]*=self.edge_clamp(a, b, pair[e]);
        }
        for &e in &self.sky {
            let i=radiation.1[e].0;
            sky_factor[e]*=self.node_clamp(i, sky[e]);
        }
        for &(i, _) in &self.nodes { air_factor[i]*=self.node_clamp(i, air[i]); }
    }

    /// 边的吞吐系数：两端受限取较小的 s，只有一端受限取该端的 s。
    fn edge_scale(&self, a: usize, b: usize) -> f64 {
        let s=|i: usize| if self.limited[i] { self.scale[i] } else { 1.0 };
        s(a).min(s(b))
    }

    /// 流向节点为正的一项热流在该节点处的钳制系数：流入取流入系数，流出取流出系数。
    fn node_clamp(&self, i: usize, q: f64) -> f64 {
        if q>0.0 { self.inflow[i] } else if q<0.0 { self.outflow[i] } else { 1.0 }
    }

    /// 边的钳制系数：两端（只看受限端）各自方向上的系数取较小者。
    fn edge_clamp(&self, a: usize, b: usize, q: f64) -> f64 {
        let k=|i: usize, q: f64| if self.limited[i] { self.node_clamp(i, q) } else { 1.0 };
        k(a, q).min(k(b, -q))
    }
}

/// 一条边相关的量计入两端（只记受限端）。
fn book_both(values: &mut [f64], limited: &[bool], a: usize, b: usize, value: f64) {
    if limited[a] { values[a]+=value; }
    if limited[b] { values[b]+=value; }
}

/// 流向 a 端为正的一项热流计入两端（只记受限端）的流入／流出合计。
fn book_flow(gain: &mut [f64], loss: &mut [f64], limited: &[bool], a: usize, b: usize, q: f64) {
    if limited[a] { book_signed(gain, loss, a, q); }
    if limited[b] { book_signed(gain, loss, b, -q); }
}

/// 流向节点 i 为正的一项热流：正值计流入，负值计流出。
fn book_signed(gain: &mut [f64], loss: &mut [f64], i: usize, q: f64) {
    if q>0.0 { gain[i]+=q; } else { loss[i]+=q; }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONE: Events = (None, None, false);

    // 只测试：四节点样本覆盖接触、互见半对、对天空、对流、有限源与耐热失血；两个小热容节点使每段多子步。
    fn sample() -> (Vec<Input>, Vec<(usize, usize, f64)>, Radiation, Vec<f64>) {
        let input = vec![
            Input(900.0, 50.0, 50.0, 500.0, 1.0, 600.0, 2.0, 0.0, 0.0, true),
            Input(293.15, 10.0, 10.0, 80.0, 1.0, 1.0e6, 1.0, 0.0, 0.0, true),
            Input(400.0, 10.0, 10.0, 120.0, 1.0, 1.0e6, 0.0, 50.0, 10.0, true),
            Input(1500.0, 5.0, 5.0, 6.7, 1.0, 1.0e6, 0.03, 0.0, 0.0, true),
        ];
        let contacts = vec![(0, 1, 3.0), (1, 2, 2.0), (2, 3, 1.5), (0, 3, 0.7)];
        let radiation = (vec![(0, 2, 0.05), (3, 1, 0.004)], vec![(1, 0.02), (3, 0.0283)]);
        (input, contacts, radiation, vec![293.15, 293.15, 280.0, 300.0])
    }

    fn bits(state: &[Output]) -> Vec<(u64, u64, u64)> {
        state.iter().map(|s| (s.0.to_bits(), s.1.to_bits(), s.2.to_bits())).collect()
    }

    // 只测试：期望是引入限流前的内核（提交 1e6afc56）对同一样本的输出位模式，冻结于 2026-11-26。
    // 证伪"不带限流参数时改变了数值"：整段推进、热前沿提前返回、旧 batch 定步长三条路径逐位相同。
    #[test]
    fn unlimited_nodes_reproduce_the_pre_throttle_kernel_bit_for_bit() {
        let (input, contacts, radiation, ambient) = sample();
        let events = vec![NONE; 4];
        let out = advance(&input, &events, &[], &contacts, &ambient, 10.0, 0.01, 0.5, &radiation);
        assert_eq!((out.elapsed.to_bits(), out.supplied.to_bits(), out.environment.to_bits()),
                   (0x3fe0000000000000, 0x4024000000000000, 0xc0bffd03ad04dec5));
        assert_eq!(bits(&out.state), vec![
            (0x408ba5e2165a0757, 0x4042ecddb33db658, 0x0), (0x40734a45ef8ce60d, 0x4024000000000000, 0x0),
            (0x4079b976b6dd7eae, 0x4024000000000000, 0x0), (0x409007402351cfba, 0x4014000000000000, 0x0)]);
        assert_eq!((out.counters.throttled, out.counters.clamped, out.counters.min_scale), (0, 0, 1.0));

        let mut cold = input.clone();
        cold[1].9 = false;
        let out = advance(&cold, &events, &[None; 4], &contacts, &ambient, 10.0, 0.01, 0.5, &radiation);
        assert_eq!((out.elapsed.to_bits(), out.supplied.to_bits(), out.environment.to_bits()),
                   (0x3fa999999999999a, 0x4004000000000000, 0xc090199344e8dff5));
        assert_eq!(bits(&out.state), vec![
            (0x408c13bd6988b64d, 0x404860d13d3b270c, 0x0), (0x40727235505e1889, 0x4024000000000000, 0x0),
            (0x407915d36e6a995f, 0x4024000000000000, 0x401e000000000000), (0x4096131eeee2ed35, 0x4014000000000000, 0x0)]);

        let (n, state, supplied, environment) = evolve(&cold, &contacts, &radiation, &ambient, 10.0, 0.01, 0.004, 40, true);
        assert_eq!((n, supplied.to_bits(), environment.to_bits()), (1, 0x3fc999999999999a, 0xc0549b9dc8d828e7));
        assert_eq!(bits(&state), vec![
            (0x408c1f04e9b90458, 0x4048f3348a04797e, 0x0), (0x407254f1d5470402, 0x4024000000000000, 0x0),
            (0x407901befe97e34f, 0x4024000000000000, 0x402399999999999a), (0x40975416f46412fa, 0x4014000000000000, 0x0)]);
    }

    // 只测试：参数从不生效（吞吐远大于热流、温度区间远宽于实际）时，受限节点与不限时逐位相同、计数为零。
    #[test]
    fn limits_that_never_bind_leave_every_value_bit_for_bit_unchanged() {
        let (mut input, contacts, radiation, ambient) = sample();
        // 热容减小到 0.5 J/K：稳定步长约 9 ms，每 50 ms 段 6 个子步。
        input[3].3 = 0.5;
        let events = vec![NONE; 4];
        let free = advance(&input, &events, &[], &contacts, &ambient, 10.0, 0.01, 0.5, &radiation);
        let wide = Some(Limit(1.0e12, 1.0, 1.0e6));
        let limited = advance(&input, &events, &[wide, None, None, wide], &contacts, &ambient, 10.0, 0.01, 0.5, &radiation);
        assert_eq!(bits(&limited.state), bits(&free.state));
        assert_eq!((limited.supplied.to_bits(), limited.environment.to_bits()), (free.supplied.to_bits(), free.environment.to_bits()));
        assert_eq!(limited.counters, Counters { steps: free.counters.steps, throttled: 0, clamped: 0, min_scale: 1.0 });
        assert!(free.counters.steps > 10, "样本应使每段多于一个子步，steps={}", free.counters.steps);
    }

    // 只测试：热结构（2000 K，C = 1000 J/K）经 g = 10 W/K 接触一个大热容冷格；单子步 dt = 0.05 s。
    // 未限流热流 10 × 1700 × 0.05 = 850 J，Φ = 1000 W → 预算 50 J，s = 1/17；两侧收付同为 50 J。
    #[test]
    fn throughput_cap_scales_the_contact_and_both_sides_book_the_same_heat() {
        let hot = Input(2000.0, 1.0, 1.0, 1000.0, 1.0, 1.0e6, 0.0, 0.0, 0.0, true);
        let cold = Input(300.0, 1.0, 1.0, 1.0e6, 1.0, 1.0e6, 0.0, 0.0, 0.0, true);
        let out = advance(&[hot, cold], &[NONE; 2], &[Some(Limit(1000.0, 0.0, 2500.0)), None], &[(0, 1, 10.0)],
                          &[300.0, 300.0], 0.0, 0.01, 0.05, &(vec![], vec![]));
        let paid = 1000.0 * (2000.0 - out.state[0].0);
        let received = 1.0e6 * (out.state[1].0 - 300.0);
        assert!((paid - 50.0).abs() < 1.0e-9 && (received - 50.0).abs() < 1.0e-6, "paid={paid} received={received}");
        assert_eq!(out.counters.steps, 1);
        assert_eq!((out.counters.throttled, out.counters.clamped), (1, 0));
        assert!((out.counters.min_scale - 1.0 / 17.0).abs() < 1.0e-15);
    }

    // 只测试：两端都受限的边取较小的 s。Φ_a = 1000 W、Φ_b = 200 W → 预算 50 J 与 10 J，边上只走 10 J。
    #[test]
    fn edge_between_two_limited_nodes_takes_the_smaller_scale() {
        let node = |t| Input(t, 1.0, 1.0, 1000.0, 1.0, 1.0e6, 0.0, 0.0, 0.0, true);
        let out = advance(&[node(2000.0), node(300.0)], &[NONE; 2],
                          &[Some(Limit(1000.0, 0.0, 3000.0)), Some(Limit(200.0, 0.0, 3000.0))], &[(0, 1, 10.0)],
                          &[300.0, 300.0], 0.0, 0.01, 0.05, &(vec![], vec![]));
        assert!((1000.0 * (2000.0 - out.state[0].0) - 10.0).abs() < 1.0e-9);
        assert!((1000.0 * (out.state[1].0 - 300.0) - 10.0).abs() < 1.0e-9);
        assert_eq!(out.counters.throttled, 2);
        assert!((out.counters.min_scale - 10.0 / 850.0).abs() < 1.0e-15);
    }

    // 只测试：四类热流同时存在、多子步时，受限节点每子步付出的能量不超过 Φ·dt，整次调用不超过 Φ·时长；
    // 全部节点的显热变化等于供能加环境交换（守恒）。
    #[test]
    fn throughput_cap_covers_all_four_flow_classes_and_conserves_energy() {
        let (input, contacts, radiation, ambient) = sample();
        let phi = 300.0;
        let limits = [None, None, None, Some(Limit(phi, 0.0, 1.0e6))];
        let out = advance(&input, &[NONE; 4], &limits, &contacts, &ambient, 10.0, 0.01, 0.5, &radiation);
        let paid = input[3].3 * (input[3].0 - out.state[3].0);
        assert!(paid > 0.0 && paid <= phi * 0.5 * (1.0 + 1.0e-12), "paid={paid}");
        let stored: f64 = input.iter().zip(&out.state).map(|(n, s)| n.3 * (s.0 - n.0)).sum();
        assert!((stored - out.supplied - out.environment).abs() < 1.0e-9 * out.environment.abs().max(1.0),
                "stored={stored} supplied={} environment={}", out.supplied, out.environment);
        assert_eq!(out.counters.throttled, 1);
    }

    // 只测试：1000 K、C = 100 J/K 的热端口接触 3000 K 大热容格（g = 50 W/K），t_hi = 1000.5 K。
    // 单子步未钳制流入 50 × 2000 × 0.05 = 5000 J，会升到 1050 K；钳制 k = 0.5 × 100 / 5000 = 0.01，恰好到 1000.5 K。
    // 之后每段都停在上限，大热容格付出的热等于结构收到的热。
    #[test]
    fn upper_clamp_stops_the_node_exactly_at_t_hi_and_keeps_both_sides_equal() {
        let port = Input(1000.0, 1.0, 1.0, 100.0, 1.0, 1.0e6, 0.0, 0.0, 0.0, true);
        let lava = Input(3000.0, 1.0, 1.0, 1.0e9, 1.0, 1.0e6, 0.0, 0.0, 0.0, true);
        let out = advance(&[port, lava], &[NONE; 2], &[Some(Limit(1.0e9, 300.0, 1000.5)), None], &[(0, 1, 50.0)],
                          &[300.0, 300.0], 0.0, 0.01, 0.5, &(vec![], vec![]));
        assert!((out.state[0].0 - 1000.5).abs() < 1.0e-9, "t={}", out.state[0].0);
        let received = 100.0 * (out.state[0].0 - 1000.0);
        let paid = 1.0e9 * (3000.0 - out.state[1].0);
        assert!((paid - received).abs() < 1.0e-4, "paid={paid} received={received}");
        assert_eq!((out.counters.throttled, out.counters.clamped), (0, 1));
    }

    // 只测试：冷端口 300 K、C = 100 J/K 接触 100 K 大热容格，t_lo = 299.9 K；未钳制流出 500 J，钳制后恰好停在下限。
    // 同时有对天空辐射（流向节点为正）和对流，钳制只缩流出项。
    #[test]
    fn lower_clamp_stops_the_node_exactly_at_t_lo() {
        let port = Input(300.0, 1.0, 1.0, 100.0, 1.0, 1.0e6, 0.01, 0.0, 0.0, true);
        let ice = Input(100.0, 1.0, 1.0, 1.0e9, 1.0, 1.0e6, 0.0, 0.0, 0.0, true);
        let out = advance(&[port, ice], &[NONE; 2], &[Some(Limit(1.0e9, 299.9, 400.0)), None], &[(0, 1, 50.0)],
                          &[293.15, 293.15], 10.0, 0.01, 0.5, &(vec![], vec![(0, 0.01)]));
        assert!((out.state[0].0 - 299.9).abs() < 1.0e-9, "t={}", out.state[0].0);
        let stored = 100.0 * (out.state[0].0 - 300.0) + 1.0e9 * (out.state[1].0 - 100.0);
        assert!((stored - out.environment).abs() < 1.0e-4);
        assert_eq!(out.counters.clamped, 1);
    }

    // 只测试：节点已高于 t_hi（拍间储能变化使上限下移）时，流入全部挡住、流出照常：接触对端逐位不变，节点只降温。
    #[test]
    fn node_already_above_t_hi_receives_nothing_but_keeps_cooling() {
        let port = Input(1100.0, 1.0, 1.0, 100.0, 1.0, 1.0e6, 0.0, 0.0, 0.0, true);
        let lava = Input(3000.0, 1.0, 1.0, 1.0e9, 1.0, 1.0e6, 0.0, 0.0, 0.0, true);
        let out = advance(&[port, lava], &[NONE; 2], &[Some(Limit(1.0e9, 300.0, 1000.0)), None], &[(0, 1, 50.0)],
                          &[300.0, 300.0], 0.0, 0.01, 0.5, &(vec![], vec![(0, 0.01)]));
        assert_eq!(out.state[1].0, 3000.0);
        assert!(out.state[0].0 < 1100.0);
        let stored = 100.0 * (out.state[0].0 - 1100.0);
        assert!((stored - out.environment).abs() < 1.0e-9);
    }

    // 只测试：设计 T15 / 附录 A.7 的最小合法热容热球——g_max 在 T_chk = 2500 K 下计算，C = 0.0556 s × g_max，
    // 稳定步长 0.45·C/g_max ≈ 25.02 ms，每 50 ms 段至多 2 个子步。热球贴着 4000 K 的大热容格（会把它往上推），
    // 旁边是 20 个普通活动格。带 t_hi = T_chk 时，0.5 s 的调用至多 2 × 10 = 20 个子步；
    // 不带限流时热球升过 2500 K，辐射线性化系数随 T³ 增大，子步数超过这一上界（说明上界来自钳制，而不是样本本身）。
    #[test]
    fn hottest_minimum_capacity_node_cannot_inflate_kernel_steps_past_the_t15_bound() {
        let (g, sky, faces, exchange) = (200.0, 0.0283, 0.03, 10.0);
        let g_max = g + 4.0 * SIGMA * sky * 2500.0_f64.powi(3) + exchange * faces;
        let capacity = 0.0556 * g_max;
        assert!(0.45 * capacity / g_max >= 0.025);
        let mut input = vec![
            Input(2500.0, 1.0, 1.0, capacity, 1.0, 1.0e6, faces, 0.0, 0.0, true),
            Input(4000.0, 1.0, 1.0, 1.0e9, 1.0, 1.0e6, 0.0, 0.0, 0.0, true),
        ];
        let mut contacts = vec![(0, 1, g)];
        for i in 0..20 {
            input.push(Input(320.0 + i as f64, 1.0, 1.0, 1000.0, 1.0, 1.0e6, 1.0, 0.0, 0.0, true));
            if i > 0 { contacts.push((i + 1, i + 2, 10.0)); }
        }
        let n = input.len();
        let radiation = (vec![], vec![(0, sky)]);
        let ambient = vec![300.0; n];
        let mut limits = vec![None; n];
        limits[0] = Some(Limit(1.0e12, 0.0, 2500.0));
        let bounded = advance(&input, &vec![NONE; n], &limits, &contacts, &ambient, exchange, 0.01, 0.5, &radiation);
        assert!(bounded.counters.steps <= 20, "steps={}", bounded.counters.steps);
        assert!(bounded.state[0].0 <= 2500.0 + 1.0e-9);
        let free = advance(&input, &vec![NONE; n], &[], &contacts, &ambient, exchange, 0.01, 0.5, &radiation);
        assert!(free.counters.steps > 20, "steps={}", free.counters.steps);
    }

    // 只测试：边界校验拒绝非有限、负吞吐、t_lo > t_hi 与长度不符的限流参数。
    #[test]
    fn invalid_limits_are_rejected_at_the_boundary() {
        let node = Input(300.0, 1.0, 1.0, 1.0, 1.0, 1.0e6, 0.0, 0.0, 0.0, true);
        let check = |limits: &[Option<Limit>]| valid(&[node], &[NONE], limits, &[], &[300.0], 0.0, 0.01, 0.5, &(vec![], vec![]));
        assert!(check(&[]) && check(&[None]) && check(&[Some(Limit(0.0, 300.0, 300.0))]));
        for bad in [Limit(-1.0, 0.0, 1.0), Limit(f64::INFINITY, 0.0, 1.0), Limit(1.0, f64::NEG_INFINITY, 1.0),
                    Limit(1.0, 2.0, 1.0), Limit(f64::NAN, 0.0, 1.0)] {
            assert!(!check(&[Some(bad)]), "{bad:?}");
        }
        assert!(!check(&[None, None]));
    }
}
