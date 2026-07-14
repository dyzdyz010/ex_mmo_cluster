defmodule SceneServer.Voxel.WorldGen do
  @moduledoc """
  Deterministic development world-seed terrain helper.

  WorldGen noise is no longer a runtime truth source. Production runtime paths
  must read authoritative voxel storage. The functions in this module remain
  available for dev migrations / local materialization tools that write their
  output into the authoritative store exactly once. XZ heightmap helpers仅供离线
  历史数据迁移；TCP `0x6A` 在线链路不会调用它们。

  Terrain shape (two summed layers): a rolling **lowland** base (fractal value noise
  centred on sea level, so it dips below into basins/valleys and rises into low
  hills) plus rare, very tall **mountains** (a low-frequency mask gates a broad
  ridged fractal up over 1 km in a few regions). Heights span many vertical chunks
  (cubic chunks, no height limit), so a chunk fills the macros whose world-y is below
  the column height — all-air chunks (above terrain) generate empty, all-solid chunks
  (deep underground) fill fast via the batched `Storage.put_solid_blocks/2`.

  The heavy per-column math (SquirrelNoise hash, octave value-noise, the lowland +
  ridged-mountain model) lives in the Rust NIF `SceneServer.Native.WorldGenNoise`
  (architecture rule: heavy compute belongs in Rust — a 1M-cell heightmap is ~39×
  faster than the old Elixir). This module is the thin server-authoritative wrapper;
  `column_height/3` and `generate_chunk_storage/3` delegate to the Rust NIF so
  dev materialization stays deterministic in `(wx, wz, seed)`.
  """

  alias SceneServer.Native.WorldGenNoise
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @chunk_size Types.chunk_size_in_macro()

  @default_seed 1337

  # Terrain band (macro units ≈ metres). The world is built as TWO layers summed:
  #   lowland — gentle rolling base centred on @sea_level that DIPS below it for
  #             basins/valleys (depressions) and rises into low hills; and
  #   mountains — rare, very TALL ridged peaks (>1 km) gated to a few regions.
  # @max_height is the air_chunk? upper bound + final clamp; it now exceeds 1 km, so
  # 历史 LOD heightmap wire (0x6B) 使用 u16 高度，旧 u8 上限为 255 m。
  #
  # 重计算(分层 value-noise:lowland 基底 + 稀疏 ridged 高山)落在 Rust NIF
  # `SceneServer.Native.WorldGenNoise`(架构纪律:重计算必须在 Rust)。所有噪声常量
  # (SquirrelNoise 哈希、octaves、mountain mask 等)现住在那个 crate 里逐字对齐。
  @sea_level 64
  @max_height 1600

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

    # 分层 value-noise 重计算落在 Rust NIF；旧 heightmap 离线工具与 chunk 共用算法。
    WorldGenNoise.column_height(wx, wz, seed, sea_level, max_height)
  end

  @doc """
  仅供历史数据迁移的 noise heightmap helper。在线 `0x6A` 已归档并明确拒绝，
  不得调用本函数或 `SceneServer.Voxel.AuthoritativeHeightmap`。
  """
  @deprecated "archived XZ heightmap offline migration helper only"
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
    seed = Keyword.get(opts, :seed, @default_seed)
    sea_level = Keyword.get(opts, :sea_level, @sea_level)
    max_height = Keyword.get(opts, :max_height, @max_height)

    # 整个 1M-cell 网格的逐列高度在 Rust 里循环填充 big-endian u16,X 优先;
    # 与 column_height 同源，供旧格式离线迁移保持确定性。
    WorldGenNoise.heightmap_region(
      origin_x,
      origin_z,
      stride,
      count_x,
      count_z,
      seed,
      sea_level,
      max_height
    )
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
end
