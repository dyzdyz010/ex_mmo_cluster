defmodule SceneServer.Native.WorldGenNoise do
  @moduledoc """
  Rustler binding for deterministic terrain-noise math.

  把 `SceneServer.Voxel.WorldGen` 里逐列高度的重计算移到 Rust(架构纪律:重计算
  必须落在 Rust)。chunk 生成与 LOD heightmap 都走同一个 `column_height/5`,保证
  地形(实体方块)与远景高度图一致。

  这个模块刻意保持极薄:只暴露 NIF surface,Rust 实现细节不渗到上层 WorldGen。
  """

  use Rustler, otp_app: :scene_server, crate: "world_gen_noise"

  @doc """
  列 `(wx, wz)` 的地表高度(第一个 air world-y),确定于 `(wx, wz, seed)`,
  clamp 到 `[0, max_height]`。
  """
  @spec column_height(integer(), integer(), integer(), integer(), integer()) :: integer()
  def column_height(_wx, _wz, _seed, _sea_level, _max_height), do: error()

  @doc """
  `count_x × count_z` 网格的服务端权威高度图:扁平 **big-endian u16**,X 优先
  (index = i + j*count_x),从列 `(origin_x, origin_z)` 起每 `stride` macros 采样。
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

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
