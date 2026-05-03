defmodule GateServer.VoxelSmoke.Paths do
  @moduledoc """
  File destinations produced by `GateServer.VoxelSmoke`.
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
