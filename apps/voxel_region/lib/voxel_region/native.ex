defmodule VoxelRegion.Native do
  @moduledoc "Voxim 世界生成 kernel 的 DirtyCpu Rustler 边界。"

  use Rustler, otp_app: :voxel_region, crate: "voxim_worldgen"

  @type config ::
          {integer(), integer(), integer(), integer(), integer(), float(), float(), integer()}

  @spec kernel_identity() :: binary()
  def kernel_identity, do: :erlang.nif_error(:nif_not_loaded)

  @spec generate_region(0..5, {integer(), integer(), integer()}, config()) :: binary()
  def generate_region(_level, _coord, _config), do: :erlang.nif_error(:nif_not_loaded)
end
