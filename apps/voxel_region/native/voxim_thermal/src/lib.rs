//! 全局系统功能：热演化的 NIF 边界。常驻的只有可丢弃的热域（拓扑 `domain` 与节点工作副本 `sim`），
//! 不持有 canonical 状态：World 的属性记录是唯一真值，节点值由 World 装入、变化由 World 取回写回。
mod domain;
mod kernel;
mod sim;

use domain::{Contact, Domain, Sight};
use kernel::{Events, Input, Output, Radiation};
#[cfg(test)]
use kernel::PhaseInput;
use rustler::{Error, NifResult, ResourceArc};
use sim::{Node, Phase, Sim};
use std::collections::HashMap;
use std::sync::Mutex;

/// World 的热域：拓扑与节点工作副本；World 丢弃工作集时随之释放。
pub struct DomainResource(Mutex<Resident>);

#[derive(Default)]
pub struct Resident {
    domain: Domain,
    sim: Sim,
}

#[rustler::resource_impl]
impl rustler::Resource for DomainResource {}

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

type Advanced = (f64, Vec<AdvanceOutput>, f64, f64);

// 纯数值调用保持原元组；World 额外声明点燃阈值、相变回写和共享完整度结算边界。
#[derive(rustler::NifUntaggedEnum)]
enum AdvanceInput {
    Controlled((Input, Events)),
    Numeric(Input),
}

/// 节点静态量：热容、导热率、耐热阈值、暴露面、所在气候区空气温度、点燃温度、共享完整度、
/// 整宏格节点的宏格编号、足迹宏格编号、相态目录值 {相变温度, 单格潜热, 单格热容, 是否液体}。
#[derive(rustler::NifTuple)]
struct NodeStatic(f64, f64, f64, f64, f64, Option<f64>, bool, Option<u32>, Vec<u32>, Option<(f64, f64, f64, bool)>);

/// 节点动态量（与属性记录对应）：温度（无记录为空气温度）、HP、MaxHP、燃料余量、燃烧功率、是否燃烧、
/// 采掘基线、相态 {有限体积, 焓, 记录已有焓}。
#[derive(rustler::NifTuple)]
struct NodeDynamic(f64, f64, f64, Option<f64>, f64, bool, Option<f64>, Option<(f64, f64, bool)>);

/// 一步结算：{实际时长, 供能, 环境交换, 燃烧耗燃, 外部节点结果, 新热格, 点燃候选, 共享损失, 熄灭, 变化节点, 有限源余量, 所请求下标的温度}。
#[derive(rustler::NifTuple)]
struct StepOut(f64, f64, f64, f64, Vec<Output>, Vec<u32>, Vec<u32>, Vec<(u32, f64, f64)>, Vec<u32>, Vec<u32>, Vec<(u32, f64)>, Vec<f64>);

fn node(s: NodeStatic, d: NodeDynamic) -> Node {
    let mut n = Node {
        capacity: s.0, conductivity: s.1, resistance: s.2, faces: s.3, ambient: s.4, ignition: s.5, shared: s.6,
        macro_cell: s.7, cells: s.8,
        phase: s.9.map(|(transition, latent, capacity, liquid)| Phase {
            transition, latent, capacity, liquid, volume: 1.0, energy: 0.0, stored: false }),
        temperature: 0.0, hp: 0.0, max_hp: 0.0, fuel: None, power: 0.0, burning: false, baseline: None,
    };
    apply(&mut n, d);
    n
}

fn apply(n: &mut Node, d: NodeDynamic) {
    (n.temperature, n.hp, n.max_hp, n.fuel, n.power, n.burning, n.baseline) = (d.0, d.1, d.2, d.3, d.4, d.5, d.6);
    if let (Some(p), Some((volume, energy, stored))) = (n.phase.as_mut(), d.7) {
        (p.volume, p.energy, p.stored) = (volume, energy, stored);
    }
}

fn dynamic(n: &Node) -> NodeDynamic {
    NodeDynamic(n.temperature, n.hp, n.max_hp, n.fuel, n.power, n.burning, n.baseline,
                n.phase.map(|p| (p.volume, p.energy, p.stored)))
}

fn finite(values: &[f64]) -> bool { values.iter().all(|v| v.is_finite()) }

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
    Ok(kernel::evolve(&input, &contacts, &(vec![], vec![]), &ambient, exchange, tolerance, dt, steps, true))
}

// 有限体积显式离散，按 50ms 分段推进焓/温度；新前沿、相变完成、点燃及共享 HP 事件交还 World。
#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
fn advance(nodes: Vec<AdvanceInput>, contacts: Vec<(usize,usize,f64)>, ambient: Ambient, exchange: f64,
           tolerance: f64, duration: f64, radiation: Radiation) -> NifResult<Advanced> {
    let (input, events): (Vec<_>, Vec<_>) = nodes.into_iter().map(unpack).unzip();
    let ambient = match ambient {
        Ambient::Uniform(a) => vec![a; input.len()],
        Ambient::PerNode(a) => a,
    };
    if !kernel::valid(&input, &events, &contacts, &ambient, exchange, tolerance, duration, &radiation) {
        return Err(Error::BadArg);
    }
    let out = kernel::advance(&input, &events, &contacts, &ambient, exchange, tolerance, duration, &radiation);
    let output = out.state.into_iter().zip(out.phases).map(|(s, p)| match p {
        Some(energy) => AdvanceOutput::Phase((s.0, s.1, s.2, energy)),
        None => AdvanceOutput::Numeric(s),
    }).collect();
    Ok((out.elapsed, output, out.supplied, out.environment))
}

fn unpack(node: AdvanceInput) -> (Input, Events) {
    match node {
        AdvanceInput::Controlled((input, events)) => (input, events),
        AdvanceInput::Numeric(input) => (input, (None, None, false)),
    }
}

#[cfg_attr(not(test), rustler::nif)]
fn domain_new() -> ResourceArc<DomainResource> {
    ResourceArc::new(DomainResource(Mutex::new(Resident::default())))
}

// 写入变化的节点接触、移除离开的槽位（连同其工作副本）、替换节点视线（`reset_sights` 时先清空全部视线）；
// 内核边与辐射项在下一次 `domain_index` 时按次序重建。
#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
fn domain_put(domain: ResourceArc<DomainResource>, nodes: Vec<(u32, Vec<Contact>)>, removed: Vec<u32>,
              sights: Vec<(u32, Vec<Sight>)>, reset_sights: bool) -> NifResult<rustler::Atom> {
    if nodes.iter().flat_map(|(_, c)| c).any(|&(_, g, _)| !g.is_finite() || g < 0.0)
        || sights.iter().flat_map(|(_, s)| s).any(|&(_, a)| !a.is_finite() || a < 0.0) {
        return Err(Error::BadArg);
    }
    let mut r = domain.0.lock().unwrap();
    r.sim.remove(&removed);
    r.domain.put(nodes, removed);
    if reset_sights { r.domain.clear_sights(); }
    r.domain.put_sights(sights);
    Ok(rustler::types::atom::ok())
}

// 装入节点的静态量与当前记录值（新加入热域，或几何／目录改变）。
#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
fn domain_load(domain: ResourceArc<DomainResource>, nodes: Vec<(u32, NodeStatic, NodeDynamic)>) -> NifResult<rustler::Atom> {
    if nodes.iter().any(|(_, s, d)| !finite(&[s.0, s.1, s.2, s.3, s.4, d.0, d.1, d.2, d.4])
        || s.0 <= 0.0 || s.2 <= 0.0 || s.3 < 0.0 || s.5.is_some_and(|t| !t.is_finite() || t <= 0.0)) {
        return Err(Error::BadArg);
    }
    domain.0.lock().unwrap().sim.load(nodes.into_iter().map(|(slot, s, d)| (slot, node(s, d))).collect());
    Ok(rustler::types::atom::ok())
}

// 按当前记录替换节点的动态量（外部事务改写、点燃之后）；`only_clean` 时跳过有待写回变化的节点。
#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
fn domain_reload(domain: ResourceArc<DomainResource>, nodes: Vec<(u32, NodeDynamic)>, only_clean: bool)
                 -> NifResult<rustler::Atom> {
    if nodes.iter().any(|(_, d)| !finite(&[d.0, d.1, d.2, d.4])) { return Err(Error::BadArg); }
    let mut r = domain.0.lock().unwrap();
    for (slot, d) in nodes { r.sim.reload(slot, only_clean, |n| apply(n, d)); }
    Ok(rustler::types::atom::ok())
}

// 热格集合（World 的 ThermalWork.hot，宏格编号）。
#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
fn domain_hot(domain: ResourceArc<DomainResource>, cells: Vec<u32>) -> rustler::Atom {
    domain.0.lock().unwrap().sim.set_hot(cells);
    rustler::types::atom::ok()
}

// 本轮节点次序（槽位列表，决定内核下标）与发边次序（同一组槽位）；返回 {边数, 互见半对数, 对天空面数}。
#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
fn domain_index(domain: ResourceArc<DomainResource>, order: Vec<u32>, emission: Vec<u32>, emissivity: f64)
                -> NifResult<(usize, usize, usize)> {
    if !emissivity.is_finite() || !(0.0..2.0).contains(&emissivity) || emission.len() != order.len() {
        return Err(Error::BadArg);
    }
    let mut r = domain.0.lock().unwrap();
    if order.iter().any(|&slot| r.sim.node(slot).is_none()) { return Err(Error::BadArg); }
    r.domain.index(&order, &emission, emissivity);
    Ok((r.domain.edges.len(), r.domain.pairs.len(), r.domain.sky.len()))
}

// 一个内核步：世界节点取自常驻工作副本（上次 `domain_index` 的次序）；外部节点（拟态、身体）的接触追加在世界边之后，
// 外部辐射项排在世界辐射项之前，与 World 端原拼接次序相同。`sources` 为 {宏格编号, 功率, 余能}，`powers` 为 {槽位, 电功率}，
// `epsilon` 为燃料耗尽阈值（VoxelRegion.Combustion.fuel_epsilon_j/0）。
#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
fn domain_step(domain: ResourceArc<DomainResource>, duration: f64, exchange: f64, tolerance: f64, epsilon: f64,
               sources: Vec<(u32, f64, f64)>, powers: Vec<(u32, f64)>, extra: Vec<AdvanceInput>,
               extra_contacts: Vec<(usize,usize,f64)>, extra_ambient: Vec<f64>, prefix: Radiation,
               requested: Vec<usize>) -> NifResult<StepOut> {
    if sources.iter().any(|&(_, p, r)| !finite(&[p, r]) || p <= 0.0) || powers.iter().any(|&(_, p)| !p.is_finite()) {
        return Err(Error::BadArg);
    }
    let mut guard = domain.0.lock().unwrap();
    let Resident { domain, sim } = &mut *guard;
    if requested.iter().any(|&i| i >= domain.nodes) { return Err(Error::BadArg); }
    let contacts = domain.edges.iter().copied().chain(extra_contacts).collect();
    let radiation = (prefix.0.into_iter().chain(domain.pairs.iter().copied()).collect(),
                     prefix.1.into_iter().chain(domain.sky.iter().copied()).collect());
    let powers: HashMap<u32, f64> = powers.into_iter().collect();
    let extra = extra.into_iter().map(unpack).collect();
    let s = sim.step(&domain.order, contacts, radiation, duration, exchange, tolerance, epsilon, &sources, &powers,
                     extra, extra_ambient, &requested).ok_or(Error::BadArg)?;
    Ok(StepOut(s.elapsed, s.supplied, s.environment, s.combustion, s.extra, s.hot, s.ignitions, s.losses,
               s.extinguished, s.changed, s.sources, s.requested))
}

// 取回自上次取回以来变化的节点当前值 {槽位, 动态量}，交 World 写回属性记录。
#[cfg_attr(not(test), rustler::nif(schedule = "DirtyCpu"))]
fn domain_flush(domain: ResourceArc<DomainResource>) -> Vec<(u32, NodeDynamic)> {
    domain.0.lock().unwrap().sim.take_dirty().iter().map(|(slot, n)| (*slot, dynamic(n))).collect()
}

// 节点当前值（不改变待写回标记）；不在热域内为 nil。
#[cfg_attr(not(test), rustler::nif)]
fn domain_values(domain: ResourceArc<DomainResource>, slots: Vec<u32>) -> Vec<Option<NodeDynamic>> {
    let r = domain.0.lock().unwrap();
    slots.into_iter().map(|slot| r.sim.node(slot).map(dynamic)).collect()
}

// 槽位在本轮节点次序中的内核下标；不在节点集内为 nil。
#[cfg_attr(not(test), rustler::nif)]
fn domain_positions(domain: ResourceArc<DomainResource>, slots: Vec<u32>) -> Vec<Option<usize>> {
    let r = domain.0.lock().unwrap();
    slots.into_iter().map(|slot| r.domain.at(slot)).collect()
}

// 上次 `domain_index` 生成的 {内核边, 互见半对, 对天空}，供核对与 World 端参考规则逐项相同。
#[cfg_attr(not(test), rustler::nif)]
fn domain_terms(domain: ResourceArc<DomainResource>) -> (Vec<(usize,usize,f64)>, Radiation) {
    let r = domain.0.lock().unwrap();
    (r.domain.edges.clone(), (r.domain.pairs.clone(), r.domain.sky.clone()))
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
