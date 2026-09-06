//! 读取 UE 独立导出的 VXR3，对完整 cells 和六向贴图逐 texel 比较。
use serde::Deserialize;
use std::{collections::BTreeMap, io::Read, path::PathBuf, time::Instant};
use voxim_worldgen::{generate_body, Config};

#[derive(Deserialize)]
struct Manifest {
    fixtures: Vec<Fixture>,
}
#[derive(Deserialize)]
struct Fixture {
    file: String,
    level: i32,
    coord: [i32; 3],
    config: (i64, i32, i32, i32, i32, f64, f64, i32),
}
struct Body {
    cells: Vec<u16>,
    skins: BTreeMap<usize, ([u16; 6], Vec<u8>)>,
}
struct Reader<'a>(&'a [u8]);
impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> &'a [u8] {
        let (first, rest) = self.0.split_at(n);
        self.0 = rest;
        first
    }
    fn u32(&mut self) -> usize {
        u32::from_le_bytes(self.take(4).try_into().unwrap()) as usize
    }
    fn array(&mut self, size: usize) -> &'a [u8] {
        let n = self.u32();
        self.take(n * size)
    }
}
fn u16s(bytes: &[u8]) -> Vec<u16> {
    bytes
        .chunks_exact(2)
        .map(|v| u16::from_le_bytes(v.try_into().unwrap()))
        .collect()
}
fn body(raw: &[u8], level: i32) -> Body {
    let mut r = Reader(raw);
    let cells = u16s(r.array(2));
    assert_eq!(cells.len(), 66usize.pow(3));
    r.take(12);
    let extent = r.u32();
    let rows: Vec<usize> = r
        .array(4)
        .chunks_exact(4)
        .map(|v| u32::from_le_bytes(v.try_into().unwrap()) as usize)
        .collect();
    let cols = u16s(r.array(2));
    let records = r.array(20);
    let fmi = u16s(r.array(2));
    let maps = r.array(1);
    r.array(8);
    assert!(r.0.is_empty());
    let mut skins = BTreeMap::new();
    let expected_extent = (1usize << level).min(4);
    for row in 0..rows.len().saturating_sub(1) {
        for k in rows[row]..rows[row + 1] {
            let record = &records[k * 20..(k + 1) * 20];
            let ids: [u16; 6] = u16s(&record[..12]).try_into().unwrap();
            let mask = u16::from_le_bytes(record[12..14].try_into().unwrap());
            let mut base = u32::from_le_bytes(record[16..20].try_into().unwrap()) as usize;
            let mut texels = Vec::new();
            for face in 0..6 {
                if mask & (1 << face) != 0 {
                    assert_eq!(extent, expected_extent);
                    let start = fmi[base] as usize * extent * extent;
                    texels.extend_from_slice(&maps[start..start + extent * extent]);
                    base += 1;
                } else {
                    texels.extend(std::iter::repeat_n(
                        ids[face] as u8,
                        expected_extent * expected_extent,
                    ));
                }
            }
            skins.insert(row * 66 + cols[k] as usize, (ids, texels));
        }
    }
    Body { cells, skins }
}
fn assert_same(expected: &Body, actual: &Body, name: &str, level: i32) {
    for (index, (a, b)) in expected.cells.iter().zip(&actual.cells).enumerate() {
        assert_eq!(
            a,
            b,
            "{name}: material at [{},{},{}]",
            index % 66,
            index / 66 % 66,
            index / (66 * 66)
        );
    }
    let extent = (1usize << level).min(4);
    for index in expected.skins.keys().chain(actual.skins.keys()) {
        let uniform = (
            [expected.cells[*index]; 6],
            vec![expected.cells[*index] as u8; 6 * extent * extent],
        );
        assert_eq!(
            expected.skins.get(index).unwrap_or(&uniform),
            actual.skins.get(index).unwrap_or(&uniform),
            "{name}: skins at [{},{},{}]",
            index % 66,
            index / 66 % 66,
            index / (66 * 66)
        );
    }
}

#[test]
#[ignore = "先用 UE Voxim.R6.S4.ExportWorldGenOracle 导出，再设置 VOXIM_ORACLE_MANIFEST"]
fn complete_ue_regions_match() {
    let path =
        PathBuf::from(std::env::var_os("VOXIM_ORACLE_MANIFEST").expect("VOXIM_ORACLE_MANIFEST"));
    let manifest: Manifest = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert!(!manifest.fixtures.is_empty());
    for fixture in manifest.fixtures {
        let bytes = std::fs::read(path.parent().unwrap().join(&fixture.file)).unwrap();
        assert_eq!(&bytes[..4], b"VXR3");
        let mut raw = Vec::new();
        match bytes[45] {
            0 => raw.extend_from_slice(&bytes[54..]),
            1 => {
                flate2::read::ZlibDecoder::new(&bytes[54..])
                    .read_to_end(&mut raw)
                    .unwrap();
            }
            _ => panic!("encoding"),
        }
        let c = fixture.config;
        let config = Config {
            seed: c.0,
            min_height: c.1,
            sea_level: c.2,
            max_height: c.3,
            soil_depth: c.4,
            lowland_amplitude: c.5,
            mountain_amplitude: c.6,
            cave_max_depth: c.7,
        };
        let start = Instant::now();
        let actual = generate_body(fixture.level, fixture.coord, &config);
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        assert_same(
            &body(&raw, fixture.level),
            &body(&actual, fixture.level),
            &fixture.file,
            fixture.level,
        );
        println!(
            "oracle={} level={} generate_ms={ms:.3} bytes={}",
            fixture.file,
            fixture.level,
            actual.len()
        );
    }
}
