//! BND-1(梯队2 step2.7a):场层本体常驻 Rust `ResourceArc` 脚手架。
//!
//! `FieldLayerSim` 持单一 field layer 的稀疏 delta(相对 `baseline`)。本步仅脚手架
//! (new/get/put/active_cells),**未接 Elixir `FieldLayer`**(原子 flip 在 2.7c);stencil
//! 读旧写新的 double-buffer scratch 在 2.7b 随计算 NIF 一并引入。布局与 Elixir
//! `Types.macro_index!` 一致(`x + y*16 + z*256`),复用 `crate::grid`。

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

use rustler::ResourceArc;

use crate::grid;
use crate::types::Aabb;

/// 量化:温度层可整数化 delta(`:integer`),其余 `:float`。
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Quant {
    Float,
    Integer,
}

/// 单 field layer 的可变状态(常驻 Rust)。
pub struct LayerState {
    /// active 缓冲:稀疏 delta(相对 `baseline`);未存即 0。
    pub values: HashMap<u16, f64>,
    pub baseline: f64,
    pub threshold: f64,
    pub quant: Quant,
}

impl LayerState {
    fn quantize(&self, v: f64) -> f64 {
        match self.quant {
            Quant::Float => v,
            Quant::Integer => v.round(),
        }
    }

    /// 写 delta(相对 baseline);`|delta| < threshold` 即删(稀疏)。与 Elixir
    /// `FieldLayer.put_delta` 等价。
    pub fn put_delta(&mut self, idx: u16, delta: f64) {
        let d = self.quantize(delta);
        if d.abs() < self.threshold {
            self.values.remove(&idx);
        } else {
            self.values.insert(idx, d);
        }
    }

    /// 读 delta(未存即 0)。
    pub fn get_delta(&self, idx: u16) -> f64 {
        *self.values.get(&idx).unwrap_or(&0.0)
    }

    /// 写绝对值(= `put_delta(value - baseline)`),与 Elixir `FieldLayer.put` 等价。
    pub fn put_absolute(&mut self, idx: u16, value: f64) {
        let baseline = self.baseline;
        self.put_delta(idx, value - baseline);
    }

    /// 把 aabb(inclusive)内所有 macro cell 置 0.0(绝对),与 Elixir `clear_layer_in_aabb`
    /// 逐位等价(那里 `FieldLayer.put(idx, 0.0)`)。
    pub fn clear_aabb(&mut self, aabb: Aabb) {
        let ((min_x, min_y, min_z), (max_x, max_y, max_z)) = aabb;

        for x in min_x..=max_x {
            for y in min_y..=max_y {
                for z in min_z..=max_z {
                    let idx = grid::macro_index((x, y, z));
                    self.put_absolute(idx, 0.0);
                }
            }
        }
    }
}

/// Rustler 资源:`Mutex<LayerState>`。Elixir 持 `ResourceArc` 句柄。
pub struct FieldLayerSim(pub Mutex<LayerState>);

#[rustler::resource_impl]
impl rustler::Resource for FieldLayerSim {}

pub type FieldLayerSimArc = ResourceArc<FieldLayerSim>;

/// 锁(poison 恢复:本数据仅 HashMap,恢复安全;不 panic 越 FFI 边界,对齐 step2.5)。
pub fn lock(sim: &FieldLayerSimArc) -> MutexGuard<'_, LayerState> {
    sim.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub fn parse_quant(s: &str) -> Quant {
    match s {
        "integer" => Quant::Integer,
        _ => Quant::Float,
    }
}

pub fn new(baseline: f64, threshold: f64, quant: Quant) -> FieldLayerSimArc {
    let baseline = match quant {
        Quant::Float => baseline,
        Quant::Integer => baseline.round(),
    };

    ResourceArc::new(FieldLayerSim(Mutex::new(LayerState {
        values: HashMap::new(),
        baseline,
        threshold,
        quant,
    })))
}

/// active cells:`[(macro_index, absolute_value)]`,过 aabb(inclusive)+ `|delta| >= epsilon`,
/// 按 idx 升序。与 Elixir `FieldLayer.active_cells` 等价。
pub fn active_cells(state: &LayerState, aabb: Aabb, epsilon: f64) -> Vec<(u16, f64)> {
    let mut out: Vec<(u16, f64)> = state
        .values
        .iter()
        .filter(|(idx, delta)| {
            let coord = grid::macro_coord(**idx);
            grid::in_aabb(coord, aabb) && delta.abs() >= epsilon
        })
        .map(|(idx, delta)| (*idx, state.baseline + delta))
        .collect();

    out.sort_by_key(|(idx, _)| *idx);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(quant: Quant) -> LayerState {
        LayerState {
            values: HashMap::new(),
            baseline: 20.0,
            threshold: 0.0001,
            quant,
        }
    }

    #[test]
    fn put_delta_sparse_below_threshold_removes() {
        let mut s = state(Quant::Float);
        s.put_delta(5, 10.0);
        assert_eq!(s.get_delta(5), 10.0);
        s.put_delta(5, 0.00001);
        assert_eq!(s.get_delta(5), 0.0);
        assert!(!s.values.contains_key(&5));
    }

    #[test]
    fn integer_quantization_rounds() {
        let mut s = state(Quant::Integer);
        s.put_delta(7, 3.6);
        assert_eq!(s.get_delta(7), 4.0);
    }

    #[test]
    fn active_cells_filters_aabb_and_epsilon_sorted() {
        let mut s = state(Quant::Float);
        // idx 0 = (0,0,0); idx 17 = (1,1,0); idx 4095 = (15,15,15)
        s.put_delta(0, 5.0);
        s.put_delta(17, 7.0);
        s.put_delta(4095, 9.0);

        // aabb 仅覆盖 (0,0,0)..(1,1,0) 含 idx 0 与 17,不含 4095。
        let aabb = ((0u8, 0u8, 0u8), (1u8, 1u8, 0u8));
        let cells = active_cells(&s, aabb, 0.0001);

        assert_eq!(cells, vec![(0u16, 25.0), (17u16, 27.0)]);
    }
}
