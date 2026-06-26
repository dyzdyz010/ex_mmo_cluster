defmodule SceneServer.Voxel.WorldGen do
  @moduledoc """
  Deterministic runtime terrain generation for the unbounded voxel world
  (阶段3 step3.1)。

  A chunk that is first touched with **no persisted row** is generated on demand
  from a global world seed — so the world has real procedural terrain everywhere a
  player can reach (a ~32×32 km showcase scale, but the noise is infinite), not
  just an empty void beyond the spawn. This is the "transmit the seed, generate
  the rest locally, only persist what changed" model: a pristine generated chunk
  is `chunk_version = 0` and is **not** persisted (it re-generates identically on
  restart / after LRU eviction); only an *edit* bumps the version and writes a row.

  Terrain shape (the layered-noise method): the surface height of each `(wx, wz)`
  world-macro column is **fractal value noise summed over octaves** (km-scale
  continental features down to fine relief) run through an **exponential shaper**
  (`≈ 2^noise`) so most of the world is gentle meadow with occasional sharp
  mountains, rather than uniform hills. Heights span many vertical chunks (cubic
  chunks, no height limit), so a chunk fills the macros whose world-y is below the
  column height — all-air chunks (above terrain) generate empty, all-solid chunks
  (deep underground) fill fast via the batched `Storage.put_solid_blocks/2`.

  Pure + dependency-free (portable SquirrelNoise lattice hash — see `lattice/3`),
  identical across runs/nodes **and across languages**, so the client can generate
  the same `chunk_version = 0` terrain locally from the seed and nothing is
  re-streamed for pristine far/LOD chunks.
  """

  import Bitwise

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @chunk_size Types.chunk_size_in_macro()

  @default_seed 1337

  # Portable lattice hash (SquirrelNoise-style) constants. Chosen over
  # `:erlang.phash2/2` so the bevy/UE clients can reproduce the SAME terrain from
  # the seed bit-for-bit (the "transmit the seed, generate the rest locally" model
  # needs a hash that exists in C++/Rust too). All arithmetic is explicit uint32.
  @u32 0xFFFFFFFF
  @noise1 0x68E31DA4
  @noise2 0xB5297A4D
  @noise3 0x1B56C4E9
  @lattice_prime 198_491_317

  # Terrain band (macro units ≈ metres). Sea level is the meadow baseline; peaks
  # reach @max_height. The world extends below 0 as solid stone (caves/biomes are
  # a later slice).
  @sea_level 64
  @max_height 224

  # Fractal octaves `{wavelength_in_macros, amplitude}` — largest is continental
  # (≈4 km features → ~8 across a 32 km span), down to fine relief.
  @octaves [
    {4096, 1.0},
    {1024, 0.5},
    {256, 0.25},
    {64, 0.125},
    {16, 0.0625}
  ]

  # Exponential height shaper exponent (the "2^noise" idea): higher → flatter
  # meadows with rarer, sharper mountains.
  @shape_exponent 3.0

  # Surface soil depth (macros of dirt below the top before stone).
  @soil_depth 4

  @type opts :: keyword()

  @doc "World seed used when none is supplied (single dev world)."
  @spec default_seed() :: integer()
  def default_seed, do: @default_seed

  @doc """
  Surface height (count of solid macro layers from y=0, i.e. the first **air**
  world-y) at world-macro column `(wx, wz)`. Deterministic in `(wx, wz, seed)`.
  """
  @spec column_height(integer(), integer(), opts()) :: integer()
  def column_height(wx, wz, opts \\ []) do
    seed = Keyword.get(opts, :seed, @default_seed)
    sea_level = Keyword.get(opts, :sea_level, @sea_level)
    max_height = Keyword.get(opts, :max_height, @max_height)

    n = fbm(wx, wz, seed)
    shaped = shape(n)
    sea_level + round(shaped * (max_height - sea_level))
  end

  @doc """
  Server-authoritative surface heightmap for a `count_x × count_z` grid starting at
  world-macro column `(origin_x, origin_z)`, sampling every `stride` macros. Returns
  a flat binary of `u8` heights (clamped 0..255; the terrain band tops out at 224),
  X fastest (index = i + j*count_x).

  This feeds the client's far/LOD terrain WITHOUT any client-side generation — the
  server (which owns the WorldGen) computes the heights and streams them, so the
  client stays a pure renderer of server truth.
  """
  @spec heightmap_region(
          integer(),
          integer(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          opts()
        ) :: binary()
  def heightmap_region(origin_x, origin_z, stride, count_x, count_z, opts \\ [])
      when stride > 0 and count_x > 0 and count_z > 0 do
    heights =
      for j <- 0..(count_z - 1), i <- 0..(count_x - 1) do
        column_height(origin_x + i * stride, origin_z + j * stride, opts) |> max(0) |> min(255)
      end

    :erlang.list_to_binary(heights)
  end

  @doc """
  Generates a chunk's `Storage` (pristine, `chunk_version = 0`) for `chunk_coord`
  from the world seed. All-air chunks return the empty storage; otherwise the
  terrain macros are filled in one batched `put_solid_blocks/2` pass.
  """
  @spec generate_chunk_storage(non_neg_integer(), Types.chunk_coord(), opts()) :: Storage.t()
  def generate_chunk_storage(logical_scene_id, {cx, cy, cz} = chunk_coord, opts \\ []) do
    base = Storage.empty(logical_scene_id, chunk_coord)
    dirt = MaterialCatalog.material_id(:dirt)
    stone = MaterialCatalog.material_id(:stone)
    soil_depth = Keyword.get(opts, :soil_depth, @soil_depth)

    entries =
      for mx <- 0..(@chunk_size - 1),
          mz <- 0..(@chunk_size - 1),
          height = column_height(cx * @chunk_size + mx, cz * @chunk_size + mz, opts),
          my <- 0..(@chunk_size - 1),
          world_y = cy * @chunk_size + my,
          world_y < height do
        material = if world_y >= height - soil_depth, do: dirt, else: stone

        {Types.macro_index!({mx, my, mz}), NormalBlockData.new(material),
         [cell_version: 0, cell_hash: 0]}
      end

    Storage.put_solid_blocks(base, entries)
  end

  @doc "Whether `chunk_coord` is entirely above the terrain (generates empty) — a cheap pre-check."
  @spec air_chunk?(Types.chunk_coord(), opts()) :: boolean()
  def air_chunk?({cx, cy, cz}, opts \\ []) do
    chunk_floor_y = cy * @chunk_size

    # If the chunk floor is at or above the maximum possible height, it is all air.
    max_height = Keyword.get(opts, :max_height, @max_height)

    if chunk_floor_y >= max_height do
      true
    else
      # Otherwise sample the columns; all below the chunk floor → all air.
      Enum.all?(0..(@chunk_size - 1), fn mx ->
        Enum.all?(0..(@chunk_size - 1), fn mz ->
          column_height(cx * @chunk_size + mx, cz * @chunk_size + mz, opts) <= chunk_floor_y
        end)
      end)
    end
  end

  # ── noise ─────────────────────────────────────────────────────────────────────

  # Fractal sum of value-noise octaves, normalised to ~[0, 1].
  defp fbm(wx, wz, seed) do
    {sum, norm} =
      @octaves
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {{wavelength, amplitude}, octave}, {sum, norm} ->
        v = value_noise(wx / wavelength, wz / wavelength, seed + octave) * amplitude
        {sum + v, norm + amplitude}
      end)

    (sum / norm) |> max(0.0) |> min(1.0)
  end

  # Convex exponential shaper in [0,1]: flat meadows, rare sharp peaks.
  defp shape(n) do
    (:math.pow(2.0, n * @shape_exponent) - 1.0) / (:math.pow(2.0, @shape_exponent) - 1.0)
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

    lerp(lerp(v00, v10, sx), lerp(v01, v11, sx), sz)
  end

  # Lattice value in [0, 1): combine the 2D integer coord into one uint32 position
  # then run the SquirrelNoise mix. Portable (no `:erlang.phash2`) so clients match.
  defp lattice(ix, iz, seed) do
    pos = band(ix + @lattice_prime * iz, @u32)
    squirrel(pos, band(seed, @u32)) / 4_294_967_296.0
  end

  # SquirrelNoise-style integer hash (Squirrel Eiserloh). All ops masked to uint32
  # so Elixir bignums behave exactly like C++/Rust native uint32 wrapping.
  defp squirrel(n, seed) do
    n = band(n * @noise1, @u32)
    n = band(n + seed, @u32)
    n = bxor(n, bsr(n, 8))
    n = band(n + @noise2, @u32)
    n = band(bxor(n, band(bsl(n, 8), @u32)), @u32)
    n = band(n * @noise3, @u32)
    bxor(n, bsr(n, 8))
  end

  defp smoothstep(t), do: t * t * (3.0 - 2.0 * t)

  defp lerp(a, b, t), do: a + (b - a) * t

  defp floor_int(value) when is_float(value), do: trunc(:math.floor(value))
  defp floor_int(value) when is_integer(value), do: value
end
