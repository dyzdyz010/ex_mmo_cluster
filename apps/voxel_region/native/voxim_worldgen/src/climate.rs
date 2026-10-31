//! 世界生成与物理气候共用的温度分数及显式Kelvin映射；不读取材料、页面或运行时目录。
use crate::{noise, world::Config};

/// 当前生成规则的雪线；生成分类与物理气候映射共用。
pub const SNOW_SCORE: f64 = 0.10;
/// 当前生成规则的苔/暖区边界；生成分类与物理气候映射共用。
pub const MOSS_SCORE: f64 = 0.22;

/// 当前规则的无量纲温度分数；reference_y为明确的canonical采样高度。
pub fn temperature_score(x: i32, reference_y: i32, z: i32, c: &Config) -> f64 {
    noise::climate(x as f64, z as f64, 1536.0, (c.seed as u32).wrapping_add(300))
        - (reference_y - c.sea_level) as f64 * 0.0008
}

/// 经构造边界校验的作者气候参数，不提供隐式Kelvin默认值。
pub struct ClimateConfig {
    cold: f64,
    warm: f64,
    height_offset: i32,
    wind: f64,
}

impl ClimateConfig {
    /// 接纳显式冷暖温度K、格采样高度偏移m与风速m/s。
    pub fn new(cold: f64, warm: f64, height_offset: i32, wind: f64) -> Option<Self> {
        if cold.is_finite() && warm.is_finite() && wind.is_finite()
            && cold > 0.0 && warm > cold && wind >= 0.0 {
            Some(Self { cold, warm, height_offset, wind })
        } else {
            None
        }
    }

    /// NIF边界一次性拒绝会使现有i32高度算术溢出的外部坐标。
    pub fn accepts(&self, cells: &[[i32;3]], c: &Config) -> bool {
        cells.iter().all(|cell| cell[1].checked_add(self.height_offset)
            .and_then(|y| y.checked_sub(c.sea_level)).is_some())
    }
}

/// 同序纯XYZ取样；调用方已经在接纳边界保证高度算术合法，不在内部重复检查。
pub fn climate_samples(cells: &[[i32;3]], c: &Config, k: &ClimateConfig) -> Vec<(f64,f64)> {
    cells.iter().map(|cell| {
        let score = temperature_score(cell[0], cell[1] + k.height_offset, cell[2], c);
        let weight = ((score - SNOW_SCORE) / (MOSS_SCORE - SNOW_SCORE)).clamp(0.0,1.0);
        (k.cold + (k.warm - k.cold) * weight, k.wind)
    }).collect()
}
