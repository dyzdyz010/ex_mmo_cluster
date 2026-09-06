//! Voxim 的纯世界生成器与 DirtyCpu NIF；坐标始终是 canonical Y-up。
mod noise;
mod skin;
mod world;

use rustler::{Binary, Env, Error, NifResult, OwnedBinary, Term};
pub use world::{generate_body, Config};

#[rustler::nif(schedule = "DirtyCpu")]
fn generate_region<'a>(
    env: Env<'a>,
    level: i32,
    coord: (i32, i32, i32),
    config: Term<'a>,
) -> NifResult<Binary<'a>> {
    if !(0..=5).contains(&level) {
        return Err(Error::BadArg);
    }
    let tuple = rustler::types::tuple::get_tuple(config)?;
    let [seed, min, sea, max, soil, lowland, mountain, cave] = tuple.as_slice() else {
        return Err(Error::BadArg);
    };
    let config = Config {
        seed: seed.decode()?,
        min_height: min.decode()?,
        sea_level: sea.decode()?,
        max_height: max.decode()?,
        soil_depth: soil.decode()?,
        lowland_amplitude: lowland.decode()?,
        mountain_amplitude: mountain.decode()?,
        cave_max_depth: cave.decode()?,
    };
    let bytes = generate_body(level, [coord.0, coord.1, coord.2], &config);
    let mut binary =
        OwnedBinary::new(bytes.len()).ok_or(Error::Term(Box::new("allocation_failed")))?;
    binary.as_mut_slice().copy_from_slice(&bytes);
    Ok(binary.release(env))
}

#[rustler::nif]
fn kernel_identity() -> &'static str {
    env!("VOXIM_KERNEL_IDENTITY")
}

rustler::init!("Elixir.VoxelRegion.Native");
