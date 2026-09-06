use voxim_worldgen::{generate_body, Config};

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
