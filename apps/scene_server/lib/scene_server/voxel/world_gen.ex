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

  # Terrain band (macro units ≈ metres). The world is built as TWO layers summed:
  #   lowland — gentle rolling base centred on @sea_level that DIPS below it for
  #             basins/valleys (depressions) and rises into low hills; and
  #   mountains — rare, very TALL ridged peaks (>1 km) gated to a few regions.
  # @max_height is the air_chunk? upper bound + final clamp; it now exceeds 1 km, so
  # the LOD heightmap wire (0x6B) carries u16 heights (the old u8 capped at 255 m).
  @sea_level 64
  @max_height 1600

  # Fractal octaves `{wavelength_in_macros, amplitude}` — continental (≈4 km) down to
  # fine relief. Used for the lowland base and (squared into ridges) the mountains.
  @octaves [
    {4096, 1.0},
    {1024, 0.7},
    {256, 0.45},
    {64, 0.25},
    {16, 0.1}
  ]

  # Lowland: peak-to-peak vertical span of the rolling base. Centred on sea level so
  # ~half dips below it → flats, gentle hills, and real basins/valleys.
  @lowland_amplitude 150

  # Mountains: a low-frequency MASK picks the FEW regions that grow ranges; within them
  # a ridged fractal built from BROAD octaves only (km-scale crests, never 16 m spikes)
  # raised to @ridge_power makes wide ridgelines that tower over 1 km at their peaks.
  @mountain_octaves [
    {4096, 1.0},
    {2048, 0.55},
    {1024, 0.28}
  ]
  @mountain_amplitude 1400
  @mountain_wavelength 9000
  @mountain_mask_lo 0.62
  @mountain_mask_hi 0.9
  @ridge_power 2.2

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

    # 1) Rolling LOWLAND base, centred on sea level so it dips below for basins/valleys
    #    (depressions) and rises into gentle hills — gives the "flat + 凹陷" character.
    base = fbm(wx, wz, seed)
    lowland = sea_level + (base - 0.5) * @lowland_amplitude

    # 2) Rare, TALL MOUNTAINS: a broad low-freq mask selects the few regions that grow
    #    ranges; within them a ridged fractal (sharp crests, raised to a power so peaks
    #    are pointy + rare) towers up to @mountain_amplitude (>1 km).
    mask = value_noise(wx / @mountain_wavelength, wz / @mountain_wavelength, seed + 100)
    gate = smoothstep_range(mask, @mountain_mask_lo, @mountain_mask_hi)
    ridge = ridged_fbm(wx, wz, seed + 200)
    mountain = @mountain_amplitude * gate * :math.pow(ridge, @ridge_power)

    round(lowland + mountain) |> max(0) |> min(max_height)
  end

  @doc """
  Server-authoritative surface heightmap for a `count_x × count_z` grid starting at
  world-macro column `(origin_x, origin_z)`, sampling every `stride` macros. Returns
  a flat binary of **big-endian u16** heights (clamped 0..65535; the terrain band
  tops out near 1.6 km so u8 no longer fits), X fastest (index = i + j*count_x).

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
    for j <- 0..(count_z - 1), i <- 0..(count_x - 1), into: <<>> do
      h = column_height(origin_x + i * stride, origin_z + j * stride, opts) |> max(0) |> min(65535)
      <<h::16-big>>
    end
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

  # Ridged fractal in ~[0,1] over the BROAD mountain octaves only: each octave folded
  # to a crest (1-|2v-1|) and squared for sharp ridgelines, summed. Using only km-scale
  # octaves keeps mountains WIDE (smooth blocky ranges), not per-cell spikes.
  defp ridged_fbm(wx, wz, seed) do
    {sum, norm} =
      @mountain_octaves
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {{wavelength, amplitude}, octave}, {sum, norm} ->
        v = value_noise(wx / wavelength, wz / wavelength, seed + octave)
        ridge = 1.0 - abs(2.0 * v - 1.0)
        {sum + ridge * ridge * amplitude, norm + amplitude}
      end)

    (sum / norm) |> max(0.0) |> min(1.0)
  end

  # Hermite smoothstep of `x` across [lo, hi] → 0 below lo, 1 above hi (the mountain
  # mask gate: 0 in lowlands, 1 in the few high-mask range regions).
  defp smoothstep_range(x, lo, hi) when hi > lo do
    t = ((x - lo) / (hi - lo)) |> max(0.0) |> min(1.0)
    t * t * (3.0 - 2.0 * t)
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
