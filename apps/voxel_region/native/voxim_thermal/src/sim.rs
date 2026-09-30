//! 全局系统功能：热域节点的工作副本与每个内核步的结算规则。
//!
//! World 的属性记录仍是唯一真值：节点在加入热域或被外部事务改写后由 World 装入，每步在这里组装内核输入、
//! 演进并结算（有限源余量、燃烧推进、热损、采掘基线、热点），World 在处理任何其他消息前与提交结束时取回变化的节点写回记录。
//! 点燃、共享完整度损失与相态焓初值仍由 World 的既有规则处理：这里只报告事件，由 World 回写后重新装入。
//! 数值与原 `ThermalBatch.prepare/6` + `ThermalSettlement.apply/5` 逐位相同（同样的算式、次序与比较）。
use crate::kernel::{self, Events, Input, Outcome, PhaseInput, Radiation};
use std::collections::{HashMap, HashSet};

/// 相态节点：相变温度、单格潜热、单格热容、是否液体（目录值），有限体积与焓（`stored` 为记录已有焓字段）。
#[derive(Clone, Copy)]
pub struct Phase {
    pub transition: f64,
    pub latent: f64,
    pub capacity: f64,
    pub liquid: bool,
    pub volume: f64,
    pub energy: f64,
    pub stored: bool,
}

/// 一个热节点：几何与目录派生的静态量，以及与属性记录对应的动态量。
#[derive(Clone)]
pub struct Node {
    pub capacity: f64,
    pub conductivity: f64,
    pub resistance: f64,
    pub faces: f64,
    pub ambient: f64,
    pub ignition: Option<f64>,
    pub shared: bool,
    /// 整宏格节点所在宏格（有限源只落在整宏格节点上）。
    pub macro_cell: Option<u32>,
    pub cells: Vec<u32>,
    pub phase: Option<Phase>,
    /// 记录温度（无记录时为所在气候区空气温度）、HP、MaxHP。
    pub temperature: f64,
    pub hp: f64,
    pub max_hp: f64,
    /// 燃料余量（记录无燃料字段为 None）、燃烧功率、是否燃烧。
    pub fuel: Option<f64>,
    pub power: f64,
    pub burning: bool,
    pub baseline: Option<f64>,
}

/// 一步结算后交还 World 的事件；节点列表均按内核下标次序。
#[derive(Default)]
pub struct Step {
    pub elapsed: f64,
    pub supplied: f64,
    pub environment: f64,
    pub combustion: f64,
    pub extra: Vec<(f64, f64, f64)>,
    pub hot: Vec<u32>,
    pub ignitions: Vec<u32>,
    /// 共享完整度节点的 {槽位, 原 HP, 内核 HP}（World 按原算式累计到部件／附件池）。
    pub losses: Vec<(u32, f64, f64)>,
    pub extinguished: Vec<u32>,
    pub changed: Vec<u32>,
    pub sources: Vec<(u32, f64)>,
    pub requested: Vec<f64>,
}

/// 一步的内核输入：实际批长、世界节点输入与事件、逐节点空气温度。
#[derive(Default)]
pub struct Batch {
    pub duration: f64,
    pub input: Vec<Input>,
    pub events: Vec<Events>,
    pub ambient: Vec<f64>,
}

#[derive(Default)]
pub struct Sim {
    nodes: Vec<Option<Node>>,
    dirty: Vec<bool>,
    hot: HashSet<u32>,
}

impl Sim {
    fn grow(&mut self, slot: u32) {
        let need = slot as usize + 1;
        if self.nodes.len() < need {
            self.nodes.resize(need, None);
            self.dirty.resize(need, false);
        }
    }

    /// 装入（或替换）节点；装入值来自当前记录，所以不再待写回。
    pub fn load(&mut self, nodes: Vec<(u32, Node)>) {
        for (slot, node) in nodes {
            self.grow(slot);
            self.nodes[slot as usize] = Some(node);
            self.dirty[slot as usize] = false;
        }
    }

    /// 按当前记录替换节点的动态量（外部事务改写或 World 点燃之后），静态量不变；
    /// `only_clean` 时有待写回变化的节点保持工作副本（其记录尚未写回，不能用旧记录覆盖）。
    pub fn reload(&mut self, slot: u32, only_clean: bool, update: impl FnOnce(&mut Node)) {
        let dirty = self.dirty.get(slot as usize).copied().unwrap_or(false);
        if only_clean && dirty { return; }
        if let Some(node) = self.nodes.get_mut(slot as usize).and_then(Option::as_mut) {
            update(node);
            self.dirty[slot as usize] = false;
        }
    }

    pub fn remove(&mut self, slots: &[u32]) {
        for &slot in slots {
            if let Some(entry) = self.nodes.get_mut(slot as usize) {
                *entry = None;
                self.dirty[slot as usize] = false;
            }
        }
    }

    pub fn node(&self, slot: u32) -> Option<&Node> {
        self.nodes.get(slot as usize).and_then(Option::as_ref)
    }

    /// 热格集合（World 的 `ThermalWork.hot`）；每步新增的热格已由本模块并入。
    pub fn set_hot(&mut self, cells: Vec<u32>) {
        self.hot = cells.into_iter().collect();
    }

    /// 取走自上次取回以来变化的节点。
    pub fn take_dirty(&mut self) -> Vec<(u32, Node)> {
        let mut out = Vec::new();
        for (slot, dirty) in self.dirty.iter_mut().enumerate() {
            if *dirty {
                *dirty = false;
                if let Some(node) = &self.nodes[slot] {
                    out.push((slot as u32, node.clone()));
                }
            }
        }
        out
    }

    /// 组装世界节点的内核输入（原 `ThermalBatch.prepare/6`）：共同批长不越过有限源与燃料耗尽点；
    /// 功率 = 电 + 燃烧 + 同宏格有限源（只落在整宏格节点），能量上限 = |功率| × 批长。
    pub fn batch(&self, order: &[u32], duration: f64, sources: &HashMap<u32, (f64, f64)>,
                 powers: &HashMap<u32, f64>, epsilon: f64) -> Batch {
        let world: Vec<&Node> = order.iter()
            .map(|&slot| self.nodes[slot as usize].as_ref().expect("indexed slot is loaded")).collect();
        let mut duration = duration;
        for &(power, remaining) in sources.values() { duration = duration.min(remaining / power); }
        for n in &world {
            if n.burning { duration = duration.min(n.fuel.unwrap_or(0.0) / n.power); }
        }
        let mut batch = Batch { duration, ..Batch::default() };
        for (&slot, n) in order.iter().zip(&world) {
            let source = n.macro_cell.and_then(|c| sources.get(&c));
            let combustion = if n.burning { n.power } else { 0.0 };
            let electric = powers.get(&slot).copied().unwrap_or(0.0);
            let power = electric + combustion + source.map_or(0.0, |s| s.0);
            let ignition = n.ignition.filter(|_| n.hp > 0.0 && !n.burning && !exhausted(n.fuel, epsilon));
            let phase = n.phase.map(|p| PhaseInput(p.energy, p.volume, p.transition, p.volume * p.latent, p.capacity, p.liquid));
            let seed = n.cells.iter().any(|c| self.hot.contains(c)) || source.is_some() || combustion > 0.0 || electric != 0.0;
            batch.input.push(Input(n.temperature, n.hp, n.max_hp, n.capacity, n.conductivity, n.resistance, n.faces,
                                   power, power.abs() * duration, seed));
            batch.events.push((ignition, phase, n.shared));
            batch.ambient.push(n.ambient);
        }
        batch
    }

    /// 结算世界节点的内核结果（原 `ThermalSettlement.apply/5` 与点燃检查）：有限源按实际时长扣减，燃烧中的节点
    /// 耗燃（`Combustion.step/2`，取尽即熄灭），相态写回焓，采掘基线随 HP 下降扣减（`Damage.pick_baseline/2`），
    /// 共享完整度节点报告损失且自身 HP 不变；与记录不同的节点记为待写回。
    pub fn settle(&mut self, order: &[u32], out: &Outcome, sources: &HashMap<u32, (f64, f64)>,
                  tolerance: f64, epsilon: f64) -> Step {
        let elapsed = out.elapsed;
        let mut step = Step { elapsed, supplied: out.supplied, environment: out.environment, ..Step::default() };
        for (i, &slot) in order.iter().enumerate() {
            let (temperature, hp, _) = out.state[i];
            let n = self.nodes[slot as usize].as_mut().unwrap();
            if let Some(cell) = n.macro_cell {
                if let Some(&(power, remaining)) = sources.get(&cell) {
                    let rest = (remaining - power * elapsed).max(0.0);
                    if rest > 1.0e-9 { step.sources.push((cell, rest)); }
                }
            }
            let (mut fuel, mut power, mut burning) = (n.fuel, n.power, n.burning);
            if n.burning && n.power > 0.0 {
                let available = n.fuel.unwrap_or(0.0).max(0.0);
                let used = available.min(n.power * elapsed);
                let rest = available - used;
                let alive = rest > epsilon && n.burning;
                (fuel, power, burning) = (Some(rest), if alive { n.power } else { 0.0 }, alive);
                step.combustion += used;
            }
            let phase = n.phase.map(|p| match out.phases[i] {
                Some(energy) => Phase { energy, stored: true, ..p },
                None => p,
            });
            let baseline = n.baseline.map(|b| (b - (n.hp - hp)).max(0.0));
            if (temperature - n.ambient).abs() > tolerance || burning {
                for &c in &n.cells {
                    if self.hot.insert(c) { step.hot.push(c); }
                }
            }
            if n.shared && hp < n.hp { step.losses.push((slot, n.hp, hp)); }
            let hp = if n.shared { n.hp } else { hp };
            let changed = temperature != n.temperature || hp != n.hp || fuel != n.fuel || power != n.power
                || burning != n.burning || baseline != n.baseline
                || phase.zip(n.phase).is_some_and(|(a, b)| !b.stored || a.energy != b.energy);
            if changed {
                if n.burning && !burning { step.extinguished.push(slot); }
                (n.temperature, n.hp, n.fuel, n.power, n.burning, n.baseline, n.phase) =
                    (temperature, hp, fuel, power, burning, baseline, phase);
                self.dirty[slot as usize] = true;
                step.changed.push(slot);
            }
        }
        // 结算后按内核次序检查可燃节点（原 ignite_heated_materials/3 的条件）；点燃由 World 的 Combustion.ignite/3 完成。
        for &slot in order {
            let n = self.nodes[slot as usize].as_ref().unwrap();
            if n.ignition.is_some_and(|t| n.hp > 0.0 && !n.burning && !exhausted(n.fuel, epsilon) && n.temperature >= t) {
                step.ignitions.push(slot);
            }
        }
        step
    }

    /// 一个内核步：`order` 是世界节点的内核次序（槽位）；`extra` 为拟态／身体等外部节点，排在世界节点之后；
    /// `epsilon` 为燃料耗尽阈值（`Combustion.fuel_epsilon_j/0`）。
    #[allow(clippy::too_many_arguments)]
    pub fn step(&mut self, order: &[u32], contacts: Vec<(usize, usize, f64)>, radiation: Radiation,
                duration: f64, exchange: f64, tolerance: f64, epsilon: f64, sources: &[(u32, f64, f64)],
                powers: &HashMap<u32, f64>, extra: Vec<(Input, Events)>, extra_ambient: Vec<f64>,
                requested: &[usize]) -> Option<Step> {
        let sources: HashMap<u32, (f64, f64)> = sources.iter().map(|&(c, p, r)| (c, (p, r))).collect();
        let Batch { duration, mut input, mut events, mut ambient } = self.batch(order, duration, &sources, powers, epsilon);
        let count = input.len();
        for (i, e) in extra { input.push(i); events.push(e); }
        ambient.extend(extra_ambient);
        if !kernel::valid(&input, &events, &contacts, &ambient, exchange, tolerance, duration, &radiation) {
            return None;
        }
        let out = kernel::advance(&input, &events, &contacts, &ambient, exchange, tolerance, duration, &radiation);
        let mut step = self.settle(order, &out, &sources, tolerance, epsilon);
        step.extra = out.state[count..].to_vec();
        step.requested = requested.iter().map(|&i| out.state[i].0).collect();
        Some(step)
    }
}

fn exhausted(fuel: Option<f64>, epsilon: f64) -> bool {
    fuel.is_some_and(|f| f <= epsilon)
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPSILON: f64 = 1.0e-9;

    // 只测试：原 ThermalBatchInputTest / ThermalSettlementTest 的样本与期望（手算），规则随实现迁入本模块。
    fn sample() -> Node {
        Node {
            capacity: 100.0, conductivity: 1.0, resistance: 1000.0, faces: 6.0, ambient: 293.15, ignition: Some(300.0),
            shared: false, macro_cell: Some(7), cells: vec![7], phase: None,
            temperature: 293.15, hp: 100.0, max_hp: 100.0, fuel: None, power: 0.0, burning: false, baseline: None,
        }
    }

    fn sim(nodes: Vec<Node>) -> (Sim, Vec<u32>) {
        let mut sim = Sim::default();
        let order: Vec<u32> = (0..nodes.len() as u32).collect();
        sim.load(order.iter().copied().zip(nodes).collect());
        (sim, order)
    }

    #[test]
    fn batch_stops_at_earliest_source_or_fuel_end_and_budgets_by_actual_length() {
        let burner = Node { burning: true, fuel: Some(0.5), power: 10.0, ..sample() };
        let sources = HashMap::from([(7, (20.0, 2.0))]);
        let (s, order) = sim(vec![burner]);
        let b = s.batch(&order, 0.5, &sources, &HashMap::from([(0, -5.0)]), EPSILON);
        assert!((b.duration - 0.05).abs() < 1.0e-12);
        assert_eq!((b.input[0].7, b.input[0].8, b.input[0].9), (25.0, 1.25, true));
        assert!(b.events[0].0.is_none() && b.events[0].1.is_none() && !b.events[0].2);

        let (s, order) = sim(vec![sample()]);
        let b = s.batch(&order, 0.5, &sources, &HashMap::new(), EPSILON);
        assert_eq!((b.duration, b.input[0].8), (0.1, 2.0));
    }

    #[test]
    fn signed_cold_power_keeps_a_positive_budget_and_reads_current_values() {
        let (s, order) = sim(vec![Node { temperature: 280.0, hp: 7.0, ..sample() }]);
        let b = s.batch(&order, 0.5, &HashMap::new(), &HashMap::from([(0, -12.0)]), EPSILON);
        let i = b.input[0];
        assert_eq!((i.0, i.1, i.2, i.7, i.8, i.9, b.duration), (280.0, 7.0, 100.0, -12.0, 6.0, true, 0.5));
    }

    #[test]
    fn exhausted_burning_or_destroyed_nodes_no_longer_request_ignition() {
        for (node, expected) in [(sample(), Some(300.0)), (Node { fuel: Some(0.0), ..sample() }, None),
                                 (Node { fuel: Some(1.0e-9), ..sample() }, None),
                                 (Node { fuel: Some(2.0e-9), ..sample() }, Some(300.0)),
                                 (Node { hp: 0.0, ..sample() }, None),
                                 (Node { burning: true, fuel: Some(5.0), power: 1.0, ..sample() }, None)] {
            let (s, order) = sim(vec![node]);
            assert_eq!(s.batch(&order, 0.5, &HashMap::new(), &HashMap::new(), EPSILON).events[0].0, expected);
        }
    }

    #[test]
    fn phase_input_uses_actual_volume_and_stored_enthalpy() {
        let phase = Phase { transition: 273.15, latent: 1000.0, capacity: 100.0, liquid: true, volume: 0.25,
                            energy: 12.0, stored: true };
        let (mut s, order) = sim(vec![Node { ignition: None, temperature: 273.15, phase: Some(phase), ..sample() }]);
        s.set_hot(vec![7]);
        let b = s.batch(&order, 0.5, &HashMap::new(), &HashMap::new(), EPSILON);
        let p = b.events[0].1.unwrap();
        assert_eq!((p.0, p.1, p.2, p.3, p.4, p.5), (12.0, 0.25, 273.15, 250.0, 100.0, true));
        assert!(b.input[0].9);
    }

    #[test]
    fn micro_and_attachment_nodes_skip_same_cell_sources_and_keep_shared_hp() {
        let fine = Node { shared: true, macro_cell: None, ..sample() };
        let (s, order) = sim(vec![fine.clone(), fine]);
        let b = s.batch(&order, 0.5, &HashMap::from([(7, (20.0, 100.0))]), &HashMap::new(), EPSILON);
        assert!(b.input.iter().zip(&b.events).all(|(i, e)| i.7 == 0.0 && !i.9 && e.2));
    }

    #[test]
    fn settlement_spends_only_the_completed_duration_and_deducts_pick_baseline() {
        let node = Node { temperature: 300.0, ambient: 300.0, hp: 10.0, max_hp: 10.0, baseline: Some(8.0), ..sample() };
        let (mut s, order) = sim(vec![node]);
        let out = Outcome { elapsed: 2.0, state: vec![(301.0, 7.0, 0.0)], phases: vec![None], supplied: 0.0, environment: 0.0 };
        let step = s.settle(&order, &out, &HashMap::from([(7, (10.0, 100.0))]), 0.01, EPSILON);
        assert_eq!(step.sources, vec![(7, 80.0)]);
        assert_eq!(step.hot, vec![7]);
        assert!(step.losses.is_empty() && step.combustion == 0.0 && step.changed == vec![0]);
        let n = s.node(0).unwrap();
        assert_eq!((n.hp, n.baseline, n.temperature), (7.0, Some(5.0), 301.0));
    }

    #[test]
    fn burning_spends_fuel_by_elapsed_time_and_goes_out_when_empty() {
        let (mut s, order) = sim(vec![Node { burning: true, fuel: Some(3.0), power: 2.0, ..sample() }]);
        let out = Outcome { elapsed: 1.0, state: vec![(900.0, 100.0, 0.0)], phases: vec![None], supplied: 0.0, environment: 0.0 };
        let step = s.settle(&order, &out, &HashMap::new(), 0.01, EPSILON);
        assert_eq!((step.combustion, s.node(0).unwrap().fuel, s.node(0).unwrap().burning), (2.0, Some(1.0), true));
        let step = s.settle(&order, &Outcome { elapsed: 1.0, ..out }, &HashMap::new(), 0.01, EPSILON);
        let n = s.node(0).unwrap();
        assert_eq!((step.combustion, n.fuel, n.burning, n.power), (1.0, Some(0.0), false, 0.0));
        assert_eq!(step.extinguished, vec![0]);
    }
}
