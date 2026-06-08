# Voxel Field

This directory owns chunk-local continuous fields. A field is runtime state, not
durable voxel truth: `FieldRegion` owns sparse `FieldLayer` values, field
kernels evolve those layers, and `FieldCodec` publishes snapshots through the
normal `0x73` client protocol.

Boundary:

- `FieldRuntime` and `FieldSource` decide when a field worker should exist.
- `FieldRegion` derives its layer set from kernel `required_layers/1`; callers
  do not pass arbitrary field type lists.
- Field kernels may evolve layers and emit structured effects, but all durable
  voxel/object writes still go through `ChunkProcess`.
- `FieldCodec` is the wire truth for browser-visible field values.

Current first-class layers:

- `temperature`: f32 Celsius values with an environment baseline of 20 C.
- `electric_potential`: f32 volts used by conduction/discharge kernels.
- `electric_current`: f32 amperes produced by closed-circuit evaluation.
- `ionization`: u8 wire values derived from the ionization layer.
- `smoke_density`: f32 percent-density values produced by combustion and
  diffused by `SmokeDiffusionKernel`.
- `oxygen`: f32 percent-availability values with a 100% ambient baseline,
  consumed by combustion and restored by `OxygenDiffusionKernel`.
- `moisture`: f32 kg/m3 water-vapor or local moisture values released by
  heated materials and diffused by `MoistureDiffusionKernel`.

Smoke is intentionally a field layer rather than only a voxel attribute. The
combustion phenomenon still writes per-voxel `smoke_density` as local truth for
debug probes and later material reactions, but visible plume spread is owned by
`SmokeDiffusionKernel` and published with field mask bit `0x10`. This keeps
combustion decisions in `Voxel.Phenomenon` while keeping continuous movement of
smoke inside the field runtime.

Oxygen follows the same scalar-field boundary. Combustion writes local
`oxygen` attributes for authoritative history, emits low-oxygen field source
points while burning, and reads active oxygen-field deficits when deciding
whether a heated material can ignite or must carbonize. `OxygenDiffusionKernel`
publishes this layer with field mask bit `0x20`.

Moisture now uses the same runtime boundary. Combustion still writes per-voxel
`moisture` after drying so chunk authority has durable material truth, but the
released water also becomes a `:moisture` field source. `MoistureDiffusionKernel`
spreads and decays that local vapor layer, and `FieldCodec` publishes it with
field mask bit `0x40`.
