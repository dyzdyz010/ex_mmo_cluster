defmodule VoxelRegion.Native do
  @moduledoc "Voxim 世界生成 kernel 的 DirtyCpu Rustler 边界。"

  use Rustler, otp_app: :voxel_region, crate: "voxim_worldgen"

  @type config ::
          {integer(), integer(), integer(), integer(), integer(), float(), float(), integer()}

  @spec kernel_identity() :: binary()
  def kernel_identity, do: :erlang.nif_error(:nif_not_loaded)

  @spec generate_region(0..5, {integer(), integer(), integer()}, config()) :: binary()
  def generate_region(_level, _coord, _config), do: :erlang.nif_error(:nif_not_loaded)

  @type bounds :: {integer(), integer(), integer(), integer()}

  @doc "一个 (level, rx, rz) 列 66-span 内列画像的折叠边界 {hmin, hmax, province_min, province_max}；DirtyCpu。"
  @spec column_bounds(0..5, {integer(), integer()}, config()) :: bounds()
  def column_bounds(_level, _coord, _config), do: :erlang.nif_error(:nif_not_loaded)

  @doc "整个 66³ region 能由边界证明均匀 → `{:uniform, material}`，否则 `:mixed`。"
  @spec classify_region(0..5, integer(), bounds(), config()) :: {:uniform, 0..255} | :mixed
  def classify_region(_level, _ry, _bounds, _config), do: :erlang.nif_error(:nif_not_loaded)

  @doc "该列上所有 `:mixed` 的 ry（升序）。"
  @spec mixed_rows(0..5, bounds(), config()) :: [integer()]
  def mixed_rows(_level, _bounds, _config), do: :erlang.nif_error(:nif_not_loaded)

  @doc "全部 cells = material、无表皮记录的 raw body，与 generate_region 对均匀 region 的输出逐字节相同。"
  @spec uniform_body(0..5, 0..255) :: binary()
  def uniform_body(_level, _material), do: :erlang.nif_error(:nif_not_loaded)
end
