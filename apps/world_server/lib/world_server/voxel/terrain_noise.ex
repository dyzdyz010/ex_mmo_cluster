defmodule WorldServer.Voxel.TerrainNoise do
  @moduledoc """
  Deterministic value-noise heightmap for dev terrain seeding.

  Pure, dependency-free (uses `:erlang.phash2/2` for the lattice hash), so the
  starter region can have visible relief — rolling hills across the multi-chunk
  platform — instead of a flat slab, without pulling in a noise library. Same
  `(world_x, world_z, seed)` always yields the same height, so seeding is
  idempotent and reproducible.

  Output `height/4` is the number of solid macro layers in a column (filled from
  `y = 0` upward), clamped to `[min_height, max_height]`.
  """

  # Lattice hash → float in [0.0, 1.0). Stable across runs/nodes.
  @hash_space 1_000_000

  @doc """
  Surface height (count of solid macro layers from y=0) at world-macro column
  `(wx, wz)`. Fractal value noise of a few octaves mapped into
  `[min_height, max_height]`.
  """
  def height(wx, wz, opts \\ []) do
    seed = Keyword.get(opts, :seed, 1337)
    min_height = Keyword.get(opts, :min_height, 2)
    max_height = Keyword.get(opts, :max_height, 15)

    n = fractal(wx * 1.0, wz * 1.0, seed)
    span = max_height - min_height
    min_height + round(n * span)
  end

  # Fractal (fBm) sum of value-noise octaves, normalized to ~[0.0, 1.0].
  defp fractal(x, z, seed) do
    o1 = value_noise(x / 24.0, z / 24.0, seed)
    o2 = value_noise(x / 12.0, z / 12.0, seed + 1) * 0.5
    o3 = value_noise(x / 6.0, z / 6.0, seed + 2) * 0.25
    sum = (o1 + o2 + o3) / 1.75
    sum |> max(0.0) |> min(1.0)
  end

  # 2D value noise at continuous (x, z): smoothstep-interpolated lattice hashes.
  defp value_noise(x, z, seed) do
    ix = floor_int(x)
    iz = floor_int(z)
    fx = x - ix
    fz = z - iz

    v00 = lattice(ix, iz, seed)
    v10 = lattice(ix + 1, iz, seed)
    v01 = lattice(ix, iz + 1, seed)
    v11 = lattice(ix + 1, iz + 1, seed)

    sx = smoothstep(fx)
    sz = smoothstep(fz)

    top = lerp(v00, v10, sx)
    bottom = lerp(v01, v11, sx)
    lerp(top, bottom, sz)
  end

  defp lattice(ix, iz, seed) do
    :erlang.phash2({ix, iz, seed}, @hash_space) / @hash_space
  end

  defp smoothstep(t), do: t * t * (3.0 - 2.0 * t)

  defp lerp(a, b, t), do: a + (b - a) * t

  defp floor_int(value) when is_float(value), do: trunc(:math.floor(value))
  defp floor_int(value) when is_integer(value), do: value
end
