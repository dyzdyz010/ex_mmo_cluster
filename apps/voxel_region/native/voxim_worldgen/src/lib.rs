//! Voxim 的纯世界生成器与 DirtyCpu NIF；坐标始终是 canonical Y-up。
mod noise;
mod skin;
mod world;

use rustler::{Binary, Env, Error, NifResult, OwnedBinary, Term};
pub use world::{
    classify_region, column_bounds, generate_body, mixed_rows, uniform_body, Config,
};

mod atoms {
    rustler::atoms! {
        mixed,
        uniform,
    }
}

fn decode_config(config: Term) -> NifResult<Config> {
    let tuple = rustler::types::tuple::get_tuple(config)?;
    let [seed, min, sea, max, soil, lowland, mountain, cave] = tuple.as_slice() else {
        return Err(Error::BadArg);
    };
    Ok(Config {
        seed: seed.decode()?,
        min_height: min.decode()?,
        sea_level: sea.decode()?,
        max_height: max.decode()?,
        soil_depth: soil.decode()?,
        lowland_amplitude: lowland.decode()?,
        mountain_amplitude: mountain.decode()?,
        cave_max_depth: cave.decode()?,
    })
}

fn level_ok(level: i32) -> NifResult<()> {
    if (0..=5).contains(&level) {
        Ok(())
    } else {
        Err(Error::BadArg)
    }
}

fn binary<'a>(env: Env<'a>, bytes: Vec<u8>) -> NifResult<Binary<'a>> {
    let mut binary =
        OwnedBinary::new(bytes.len()).ok_or(Error::Term(Box::new("allocation_failed")))?;
    binary.as_mut_slice().copy_from_slice(&bytes);
    Ok(binary.release(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn generate_region<'a>(
    env: Env<'a>,
    level: i32,
    coord: (i32, i32, i32),
    config: Term<'a>,
) -> NifResult<Binary<'a>> {
    level_ok(level)?;
    let config = decode_config(config)?;
    binary(env, generate_body(level, [coord.0, coord.1, coord.2], &config))
}

/// 一列的折叠边界 `{hmin, hmax, province_min, province_max}`；L5 一列要算四百万个列高，走 DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu", name = "column_bounds")]
fn column_bounds_nif(level: i32, coord: (i32, i32), config: Term) -> NifResult<(i32, i32, i32, i32)> {
    level_ok(level)?;
    let config = decode_config(config)?;
    let [a, b, c, d] = column_bounds(level, [coord.0, coord.1], &config);
    Ok((a, b, c, d))
}

/// `{:uniform, material}` / `:mixed`。
#[rustler::nif(name = "classify_region")]
fn classify_region_nif<'a>(
    env: Env<'a>,
    level: i32,
    ry: i32,
    bounds: (i32, i32, i32, i32),
    config: Term<'a>,
) -> NifResult<Term<'a>> {
    use rustler::Encoder;
    level_ok(level)?;
    let config = decode_config(config)?;
    Ok(
        match classify_region(level, ry, [bounds.0, bounds.1, bounds.2, bounds.3], &config) {
            Some(material) => (atoms::uniform(), material).encode(env),
            None => atoms::mixed().encode(env),
        },
    )
}

#[rustler::nif(name = "mixed_rows")]
fn mixed_rows_nif(level: i32, bounds: (i32, i32, i32, i32), config: Term) -> NifResult<Vec<i32>> {
    level_ok(level)?;
    let config = decode_config(config)?;
    Ok(mixed_rows(level, [bounds.0, bounds.1, bounds.2, bounds.3], &config))
}

#[rustler::nif(name = "uniform_body")]
fn uniform_body_nif(env: Env, level: i32, material: u16) -> NifResult<Binary> {
    level_ok(level)?;
    binary(env, uniform_body(level, material))
}

#[rustler::nif]
fn kernel_identity() -> &'static str {
    env!("VOXIM_KERNEL_IDENTITY")
}

rustler::init!("Elixir.VoxelRegion.Native");
