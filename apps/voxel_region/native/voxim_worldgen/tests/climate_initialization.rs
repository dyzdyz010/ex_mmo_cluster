//! 只测试：正式生成参数的有限天然样本与原热内核；不启动World、不改发布资产、不宣称全世界稳态。
#![allow(dead_code)]

#[path = "../src/noise.rs"]
mod noise;
#[path = "../../voxim_thermal/src/kernel.rs"]
mod thermal_kernel;

use serde_json::Value;
use std::{fs, path::Path};
use thermal_kernel::{Events, Input, PhaseInput};
use voxim_worldgen::{generate_body, Config};

// 只测试：作者可调Kelvin提案参数，尚非生产资产值；采样高度取宏格上表面。
const COLD_K: f64 = 263.15;
const WARM_K: f64 = 293.15;
const HEIGHT_OFFSET_M: f64 = 1.0;

fn json(path: &Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

fn material(catalog: &Value, id: u16) -> &Value {
    catalog["materials"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["material_id"].as_u64() == Some(id as u64))
        .unwrap()
}

fn number(row: &Value, key: &str) -> f64 {
    row[key].as_f64().unwrap()
}

fn config(manifest: &Value) -> Config {
    Config {
        seed: manifest["seed"].as_i64().unwrap(),
        min_height: manifest["min_height"].as_i64().unwrap() as i32,
        sea_level: manifest["sea_level"].as_i64().unwrap() as i32,
        max_height: manifest["max_height"].as_i64().unwrap() as i32,
        soil_depth: manifest["soil_depth"].as_i64().unwrap() as i32,
        lowland_amplitude: number(manifest, "lowland_amplitude"),
        mountain_amplitude: number(manifest, "mountain_amplitude"),
        cave_max_depth: manifest["cave_max_depth"].as_i64().unwrap() as i32,
    }
}

// 只测试：重用现有Rust噪声函数构造待审阅的气候输入，不把此助手当生产取样器。
fn score(cell: [i32; 3], c: &Config) -> f64 {
    noise::climate(
        cell[0] as f64,
        cell[2] as f64,
        1536.0,
        (c.seed as u32).wrapping_add(300),
    ) - (cell[1] as f64 + HEIGHT_OFFSET_M - c.sea_level as f64) * 0.0008
}

fn air(cell: [i32; 3], c: &Config) -> f64 {
    let weight = ((score(cell, c) - 0.10) / (0.22 - 0.10)).clamp(0.0, 1.0);
    COLD_K + (WARM_K - COLD_K) * weight
}

fn cells(body: &[u8]) -> Vec<u16> {
    assert_eq!(
        u32::from_le_bytes(body[..4].try_into().unwrap()),
        66u32.pow(3)
    );
    body[4..4 + 2 * 66usize.pow(3)]
        .chunks_exact(2)
        .map(|v| u16::from_le_bytes(v.try_into().unwrap()))
        .collect()
}

// 只测试：验收必须显式提供既有基底与独占候选输出；不创建或覆盖旧字节。
fn baseline(body: &[u8], name: &str) {
    let root = std::env::var("VOXIM_CLIMATE_BASELINE").expect("L0验收必须显式提供VOXIM_CLIMATE_BASELINE");
    let output = std::env::var("VOXIM_CLIMATE_OUTPUT").expect("L0验收必须显式提供VOXIM_CLIMATE_OUTPUT");
    let path = Path::new(&root).join(name);
    let previous = fs::read(&path).expect("L0验收的改前基底缺失，不得创建替代基底");
    let candidate = Path::new(&output).join(name);
    assert!(!candidate.exists(), "候选证据已经存在，必须使用新的独占输出目录");
    fs::write(&candidate, body).unwrap();
    let equal = body == previous.as_slice();
    println!("L0_COMPARE baseline_root={root:?} old={path:?} new={candidate:?} old_bytes={} new_bytes={} bytes_equal={equal}",
        previous.len(), body.len());
    assert!(equal, "重构改变L0完整载荷，保留old/new文件供SHA核对");
}

fn index(local: [usize; 3]) -> usize {
    local[0] + 66 * (local[1] + 66 * local[2])
}

fn global(local: [usize; 3], region: [i32; 3]) -> [i32; 3] {
    std::array::from_fn(|axis| region[axis] * 64 - 1 + local[axis] as i32)
}

fn basic(row: &Value, temperature: f64, faces: f64, power: f64, remaining: f64) -> Input {
    Input(
        temperature,
        number(row, "max_hp_per_macro"),
        number(row, "max_hp_per_macro"),
        number(row, "heat_capacity_per_macro"),
        number(row, "thermal_conductivity"),
        number(row, "heat_resistance_kelvin"),
        faces,
        power,
        remaining,
        true,
    )
}

fn step(
    input: &[Input],
    events: &[Events],
    contacts: &[(usize, usize, f64)],
    ambient: &[f64],
    environment: &Value,
    radiation: &(Vec<(usize, usize, f64)>, Vec<(usize, f64)>),
) -> thermal_kernel::Outcome {
    let exchange = number(environment, "environment_w_per_m2_k");
    let tolerance = number(environment, "tolerance_kelvin");
    assert!(thermal_kernel::valid(
        input, events, contacts, ambient, exchange, tolerance, 0.5, radiation
    ));
    thermal_kernel::advance(
        input, events, contacts, ambient, exchange, tolerance, 0.5, radiation,
    )
}

#[test]
#[ignore = "显式指定正式发布manifest/material/environment路径；有限原生试算，不启动服务"]
fn published_patch_cold_snow_gradient_and_finite_heat() {
    let manifest_path = std::env::var("VOXIM_CLIMATE_MANIFEST").unwrap();
    let catalog_path = std::env::var("VOXIM_CLIMATE_CATALOG").unwrap();
    let environment_path = std::env::var("VOXIM_CLIMATE_ENVIRONMENT").unwrap();
    let manifest = json(Path::new(&manifest_path));
    let catalog = json(Path::new(&catalog_path));
    let environment = json(Path::new(&environment_path));
    let c = config(&manifest);
    let region = [0, 7, 0];
    let body = generate_body(0, region, &c);
    baseline(&body, "before-snow-L0.body");
    let natural = cells(&body);
    let snow_local = (1..65)
        .flat_map(|z| (1..65).flat_map(move |y| (1..65).map(move |x| [x, y, z])))
        .find(|&p| natural[index(p)] == 4)
        .expect("有限region没有天然雪；保留此反例，不扩大为世界扫描");
    let snow_cell = global(snow_local, region);
    assert!(score(snow_cell, &c) < 0.10);
    assert_eq!(air(snow_cell, &c), COLD_K);
    let snow = material(&catalog, 4);
    let transition = number(snow, "phase_transition_kelvin");
    let latent = number(snow, "latent_heat_per_macro_j");
    let capacity = number(snow, "heat_capacity_per_macro");
    let initial_energy = capacity * (COLD_K - transition);
    let phase = Some(PhaseInput(
        initial_energy,
        1.0,
        transition,
        latent,
        capacity,
        false,
    ));
    let radiation = (vec![], vec![(0, number(&environment, "emissivity"))]);
    let stable = step(
        &[basic(snow, COLD_K, 1.0, 0.0, 0.0)],
        &[(None, phase, false)],
        &[],
        &[COLD_K],
        &environment,
        &radiation,
    );
    assert_eq!(stable.phases[0], Some(initial_energy));
    assert_eq!(stable.state[0].0, COLD_K);
    assert_eq!(stable.supplied, 0.0);
    assert_eq!(stable.environment, 0.0);
    println!("NATURAL_SNOW cell={snow_cell:?} region={region:?} score={} air_k={COLD_K} energy_j={initial_energy} stable_s={}",
        score(snow_cell, &c), stable.elapsed);

    // 只测试：同XZ竖直向下取score≈.16的真实固体接触，第二个且最后一个生成region。
    let base = noise::climate(
        snow_cell[0] as f64,
        snow_cell[2] as f64,
        1536.0,
        (c.seed as u32).wrapping_add(300),
    );
    let y = (c.sea_level as f64 + (base - 0.16) / 0.0008 - HEIGHT_OFFSET_M).floor() as i32;
    let lower = [snow_cell[0], y, snow_cell[2]];
    let upper = [snow_cell[0], y + 1, snow_cell[2]];
    let deep_region = lower.map(|v| v.div_euclid(64));
    let body = generate_body(0, deep_region, &c);
    baseline(&body, "before-gradient-L0.body");
    let deep = cells(&body);
    let local =
        |p: [i32; 3]| std::array::from_fn(|axis| (p[axis] - deep_region[axis] * 64 + 1) as usize);
    let ids = [deep[index(local(lower))], deep[index(local(upper))]];
    assert!(ids
        .iter()
        .all(|&id| id != 0 && id != 4 && id != 20 && id != 21));
    let rows = [material(&catalog, ids[0]), material(&catalog, ids[1])];
    let ambient = [air(lower, &c), air(upper, &c)];
    let input = [
        basic(rows[0], ambient[0], 0.0, 0.0, 0.0),
        basic(rows[1], ambient[1], 0.0, 0.0, 0.0),
    ];
    let conductance = 2.0 * input[0].4 * input[1].4 / (input[0].4 + input[1].4);
    let gradient = step(
        &input,
        &[(None, None, false); 2],
        &[(0, 1, conductance)],
        &ambient,
        &environment,
        &(vec![], vec![]),
    );
    assert_ne!(gradient.state[0].0, ambient[0]);
    assert_ne!(gradient.state[1].0, ambient[1]);
    let delta: Vec<_> = (0..2)
        .map(|i| input[i].3 * (gradient.state[i].0 - ambient[i]))
        .collect();
    let residual = delta.iter().sum::<f64>() - gradient.supplied - gradient.environment;
    assert!(residual.abs() < 1e-6, "实际内核梯度账残差={residual}");
    println!("INITIAL_GRADIENT cells={lower:?}/{upper:?} material={ids:?} air_k={ambient:?} after_k={:?} delta_j={delta:?} environment_j={} residual_j={residual}",
        gradient.state.iter().map(|s| s.0).collect::<Vec<_>>(), gradient.environment);

    // 只测试：中心真实六邻完整接触的首个显式子步，排除两节点截边本身造成中心通量的解释。
    let stencil = [lower, [lower[0]-1,lower[1],lower[2]], [lower[0]+1,lower[1],lower[2]],
        [lower[0],lower[1]-1,lower[2]], [lower[0],lower[1]+1,lower[2]],
        [lower[0],lower[1],lower[2]-1], [lower[0],lower[1],lower[2]+1]];
    let stencil_ids: Vec<_> = stencil.iter().map(|&p| deep[index(local(p))]).collect();
    assert!(stencil_ids.iter().all(|&id| id == 11));
    let ambient: Vec<_> = stencil.iter().map(|&p| air(p,&c)).collect();
    let inputs: Vec<_> = ambient.iter().map(|&t| basic(material(&catalog,11),t,0.0,0.0,0.0)).collect();
    let contacts: Vec<_> = (1..7).map(|i| (0,i,inputs[0].4)).collect();
    let events = vec![(None,None,false); 7];
    let radiation = (vec![],vec![]);
    let exchange = number(&environment,"environment_w_per_m2_k");
    let tolerance = number(&environment,"tolerance_kelvin");
    assert!(thermal_kernel::valid(&inputs,&events,&contacts,&ambient,exchange,tolerance,0.05,&radiation));
    let first = thermal_kernel::advance(&inputs,&events,&contacts,&ambient,exchange,tolerance,0.05,&radiation);
    let central_delta = inputs[0].3*(first.state[0].0-ambient[0]);
    assert!(central_delta.abs()>1e-8, "中心完整六邻首步仍须存在真实非零初始通量");
    println!("FULL_SIX_NEIGHBOR cell={lower:?} material={stencil_ids:?} initial_k={} after_k={} delta_j={central_delta} elapsed_s={}",
        ambient[0],first.state[0].0,first.elapsed);

    // 只测试：纯算法输入的有限能源，不冒称World付费/公开工具/日志恢复验收。
    let budget = latent - initial_energy + 5000.0;
    let heated = step(
        &[basic(snow, COLD_K, 1.0, 1e9, budget)],
        &[(None, phase, false)],
        &[],
        &[COLD_K],
        &environment,
        &(vec![], vec![(0, number(&environment, "emissivity"))]),
    );
    let energy = heated.phases[0].unwrap();
    assert!(energy >= latent, "有限供能必须达到完整潜热");
    assert!(heated.state[0].2 < budget && heated.state[0].2 >= 0.0);
    let heat_residual = energy - initial_energy - heated.supplied - heated.environment;
    assert!(heat_residual.abs() < 1e-5, "有限供能焓残差={heat_residual}");
    println!("FINITE_HEAT elapsed_s={} budget_j={budget} remaining_j={} supplied_j={} environment_j={} phase_energy_j={energy} latent_j={latent} residual_j={heat_residual}",
        heated.elapsed, heated.state[0].2, heated.supplied, heated.environment);
}
