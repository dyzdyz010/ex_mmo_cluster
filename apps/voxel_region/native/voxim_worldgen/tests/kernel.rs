use voxim_worldgen::{classify_region, column_bounds, generate_body, mixed_rows, uniform_body, Config};

#[test]
fn deep_l0_is_complete_basalt_region() {
    let body = generate_body(0, [0, -10, 0], &Config::default());
    assert!(body.len() >= 4 + 66 * 66 * 66 * 2);
    assert_eq!(
        u32::from_le_bytes(body[..4].try_into().unwrap()),
        66u32.pow(3)
    );
    assert!(body[4..4 + 66 * 66 * 66 * 2]
        .chunks_exact(2)
        .all(|v| v == [13, 0]));
}

fn cells_of(body: &[u8]) -> Vec<u16> {
    body[4..4 + 66 * 66 * 66 * 2]
        .chunks_exact(2)
        .map(|v| u16::from_le_bytes([v[0], v[1]]))
        .collect()
}

/// 线上 Demo 曾将这一整列截成 586 米的平台；生成与分类都必须保留原始山峰。
#[test]
fn demo_peaks_survive_above_legacy_height_limit() {
    let config = Config {
        min_height: -200, sea_level: 326, max_height: 586,
        lowland_amplitude: 381.77066, mountain_amplitude: 1223.743774,
        ..Config::default()
    };
    let bounds = column_bounds(0, [7, -7], &config);
    assert!(bounds[0] > 586 && bounds[1] > bounds[0], "{bounds:?}");
    let cells = cells_of(&generate_body(0, [7, 9, -7], &config));
    // 同一 600 米水平切片同时有空气和山体，排除仅把整个平台抬高。
    let y = 600 - (9 * 64 - 1);
    let slice: Vec<_> = (1..65).flat_map(|z| (1..65).map(move |x| x + 66 * (y + 66 * z)))
        .map(|index| cells[index]).collect();
    assert!(slice.iter().any(|&m| m == 0));
    assert!(slice.iter().any(|&m| m != 0));
}

/// 列边界 + 分类必须与 generate_body 一致：说均匀的 region 逐字节等于 uniform_body，
/// mixed_rows 之外的 ry 全部均匀，而 mixed_rows 里至少含地表所在的那一行（cells 不全相同）。
#[test]
fn region_classification_matches_generate_body() {
    let config = Config::default();
    for level in 0..=2 {
        let bounds = column_bounds(level, [0, 0], &config);
        assert!(bounds[0] <= bounds[1] && bounds[0] >= config.min_height && bounds[1] <= config.max_height);
        let mixed = mixed_rows(level, bounds, &config);
        assert!(!mixed.is_empty());
        let (lo, hi) = (mixed[0] - 1, mixed[mixed.len() - 1] + 1);
        let mut seen_air = false;
        let mut seen_rock = false;
        let mut seen_surface = false;
        for ry in lo..=hi {
            let body = generate_body(level, [0, ry, 0], &config);
            match classify_region(level, ry, bounds, &config) {
                Some(material) => {
                    assert!(!mixed.contains(&ry));
                    assert_eq!(body, uniform_body(level, material), "L{level} ry={ry} m={material}");
                    if material == 0 {
                        seen_air = true;
                    } else {
                        seen_rock = true;
                    }
                }
                None => {
                    assert!(mixed.contains(&ry));
                    let cells = cells_of(&body);
                    if cells.iter().any(|&m| m == 0) && cells.iter().any(|&m| m != 0) {
                        seen_surface = true;
                    }
                }
            }
        }
        assert!(seen_air && seen_rock && seen_surface, "L{level}: air={seen_air} rock={seen_rock} surface={seen_surface}");
        // mixed_rows 之外更远的行也均匀（分类不依赖扫描范围）。
        assert!(classify_region(level, lo - 5, bounds, &config).is_some());
        assert!(classify_region(level, hi + 5, bounds, &config).is_some());
    }
}

/// Cross-language oracle from the actual UE generator, including ring cells.
#[test]
#[ignore = "Export Voxim.Gameplay.WorldgenResources and set VOXIM_GAMEPLAY_ORACLE"]
fn gameplay_client_tiles_match() {
    let folder = std::env::var("VOXIM_GAMEPLAY_ORACLE").unwrap();
    for entry in std::fs::read_dir(folder).unwrap() {
        let file = entry.unwrap().path();
        if file.extension().unwrap() != "cells" { continue; }
        let xyz: Vec<i32> = file.file_stem().unwrap().to_str().unwrap().split('_').map(|s| s.parse().unwrap()).collect();
        let coord = [xyz[0],xyz[1],xyz[2]];
        let expected = std::fs::read(file).unwrap();
        let body = generate_body(0,coord,&Config::default());
        assert_eq!(expected.as_slice(), &body[4..4+66*66*66*2], "{coord:?}");
    }
}
