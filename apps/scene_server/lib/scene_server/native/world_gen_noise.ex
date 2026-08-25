defmodule SceneServer.Native.WorldGenNoise do
  @moduledoc """
  确定性地形噪声的极薄 Rustler 边界。

  canonical chunk 入口在 DirtyCpu scheduler 上生成世界坐标连续的 XYZ 材质体；旧
  `column_height/5` 与 `heightmap_region/8` 只为历史离线迁移保留。地表基底与三维
  cheese-cave 的算法身份、常量和重计算均由 Rust 唯一拥有，在线运行时不读取 heightmap，
  上层也不接触噪声实现细节。
  """

  use Rustler, otp_app: :scene_server, crate: "world_gen_noise"

  @doc "当前 canonical XYZ 材质体算法身份；改变输出语义时必须随 Rust owner 一起换版。"
  @spec algorithm_version() :: String.t()
  def algorithm_version, do: error()

  @doc """
  列 `(wx, wz)` 的地表高度(第一个 air world-y),确定于 `(wx, wz, seed)`,
  clamp 到 `[0, max_height]`。
  """
  @spec column_height(integer(), integer(), integer(), integer(), integer()) :: integer()
  def column_height(_wx, _wz, _seed, _sea_level, _max_height), do: error()

  @doc """
  `count_x × count_z` 网格的历史 heightmap 离线迁移输出：扁平 **big-endian u16**，
  X 优先 (index = i + j*count_x)，从列 `(origin_x, origin_z)` 起每 `stride` macros 采样。
  """
  @spec heightmap_region(
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer()
        ) :: binary()
  def heightmap_region(
        _origin_x,
        _origin_z,
        _stride,
        _count_x,
        _count_z,
        _seed,
        _sea_level,
        _max_height
      ),
      do: error()

  @doc """
  生成固定 16x16x16 canonical XYZ 材质体。

  binary 按 `x + y*16 + z*256` 排列 big-endian u16 material id；其余返回值依次为
  solid、cave-air、surface、subsurface 计数。重计算由 Rust NIF 的 DirtyCpu scheduler 承担。
  """
  @spec chunk_materials(
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          non_neg_integer(),
          pos_integer(),
          1..65_535,
          1..65_535
        ) ::
          {binary(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def chunk_materials(
        _origin_x,
        _origin_y,
        _origin_z,
        _seed,
        _sea_level,
        _max_height,
        _soil_depth,
        _surface_material_id,
        _subsurface_material_id
      ),
      do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
