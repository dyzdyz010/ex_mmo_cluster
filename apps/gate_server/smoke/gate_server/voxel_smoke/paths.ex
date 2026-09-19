defmodule GateServer.VoxelSmoke.Paths do
  @moduledoc """
  只测试：`GateServer.VoxelSmoke` 的观测文件路径。
  """

  @enforce_keys [
    :gate_observe_log,
    :scene_observe_log,
    :world_observe_log,
    :stdio_log,
    :summary_path
  ]
  defstruct @enforce_keys
end
