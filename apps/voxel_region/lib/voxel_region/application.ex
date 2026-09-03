defmodule VoxelRegion.Application do
  @moduledoc """
  Voxim R6 的 region 真值应用（S1 文件后端 + S2 overlay 日志）。

  `config :voxel_region, :root`（`VOXEL_REGION_ROOT`，= Voxim 的 `WorldBake/`）非空时启动一个 `VoxelRegion.World`：
  truth = 烘焙文件 ⊕ overlay 日志。auth_server 的 `POST /ingame/voxel/regions` 与 gate_server 的
  `0x76 OverlaySubscribe` / `0x70 VoxelEditIntent`（Voxim 会话）/ `0x77 VoxelLogEntry` 都打到它。
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:voxel_region, :root) do
        nil -> []
        "" -> []
        root -> [{VoxelRegion.World, root: root}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: VoxelRegion.Supervisor)
  end
end
