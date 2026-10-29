//! 只测试：明确XYZ与显式作者参数的纯气候取样，不启动世界或读取发布资产。
use voxim_worldgen::{climate_samples, temperature_score, ClimateConfig, Config};

#[test]
fn xyz_samples_preserve_order_and_do_not_depend_on_material_or_current_height() {
    let c = Config { min_height: -200, sea_level: 326, max_height: 586,
        lowland_amplitude: 381.77066, mountain_amplitude: 1223.743774, ..Config::default() };
    let k = ClimateConfig::new(263.15, 293.15, 1, 0.0).unwrap();
    let points = [[62,493,0], [62,278,0], [62,-200,0], [-62,493,-1], [62,493,0]];
    let result = climate_samples(&points, &c, &k);
    assert_eq!(result.len(), points.len());
    assert_eq!(result[0], (263.15, 0.0));
    assert_eq!(result[2], (293.15, 0.0));
    assert_eq!(result[0], result[4]);
    assert!((result[1].0 - 278.21551838090727).abs() < 1e-12);
    assert_eq!(result[1], climate_samples(&[points[1]], &c, &k)[0]);
    assert_eq!(temperature_score(62,494,0,&c), -0.011737926476370966);
    assert!(climate_samples(&[], &c, &k).is_empty());
}

#[test]
fn author_kelvin_and_wind_are_explicit_and_invalid_parameters_fail() {
    let c = Config { sea_level: 326, ..Config::default() };
    let k = ClimateConfig::new(253.15, 303.15, 1, 4.0).unwrap();
    assert!(k.accepts(&[[-62, -493, -1]], &c));
    assert!(!k.accepts(&[[0, i32::MAX, 0]], &c));
    assert_eq!(climate_samples(&[[62,493,0]], &c, &k), vec![(253.15,4.0)]);
    for (cold,warm,wind) in [(0.0,293.15,0.0),(293.15,263.15,0.0),
        (263.15,f64::NAN,0.0),(263.15,293.15,-1.0)] {
        assert!(ClimateConfig::new(cold,warm,1,wind).is_none());
    }
}
