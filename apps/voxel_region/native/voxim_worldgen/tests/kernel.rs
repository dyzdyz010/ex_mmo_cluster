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
