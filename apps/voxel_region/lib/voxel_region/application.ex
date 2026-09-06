defmodule VoxelRegion.Application do
  @moduledoc """
  Voxim R6 的 region 真值应用（S4 在线生成基底 + overlay 日志）。

  `config :voxel_region, :root` 与 `:manifest_path` 非空时先跑 `VoxelRegion.Bake`（L1–L5 全世界 baseline 齐全才算 ready，
  之前本应用不完成启动、依赖它的 auth/gate 也不会开始监听），再启动一个 `VoxelRegion.World`：
  truth = 显式生成 manifest ⊕ overlay 日志。auth_server 的 `POST /ingame/voxel/regions` 与 gate_server 的
  `0x76 OverlaySubscribe` / `0x70 VoxelEditIntent`（Voxim 会话）/ `0x77 VoxelLogEntry` 都打到它。
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:voxel_region, :root) do
        nil ->
          []

        "" ->
          []

        root ->
          manifest_path =
            Application.get_env(:voxel_region, :manifest_path) ||
              raise "VOXEL_REGION_MANIFEST is required when VOXEL_REGION_ROOT is set"

          opts = [source: VoxelRegion.GeneratedStore, root: root, manifest_path: manifest_path]
          {:ok, store} = VoxelRegion.GeneratedStore.open(opts)
          {:ok, _store, _stats} = VoxelRegion.Bake.run(store)
          [{VoxelRegion.World, opts}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: VoxelRegion.Supervisor)
  end
end
