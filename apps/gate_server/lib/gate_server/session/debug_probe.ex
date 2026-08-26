defmodule GateServer.Session.DebugProbe do
  @moduledoc """
  `0x6E VoxelDebugProbe` 命令的执行入口 —— Gate 会话的非 GUI 调试面。

  探针只读运行时状态或触发**显式**的调试动作（如 `voxel_rebind`），永远不改业务真值；
  未知命令回 `voxel_debug=unknown_command`，不猜、不静默成功。

  ## 命令

  - `voxel_transport` —— 连接状态 + 订阅集 + 路由摘要
  - `voxel_rebind <logical_scene_id> [region_id|all]` —— 强制重绑订阅（换 owner / 换 epoch
    后的人工修复通道），随后附带一份 `voxel_transport` 快照便于对比
  """

  alias GateServer.Session.Observe
  alias GateServer.Voxel.SubscriptionWorker

  @doc """
  执行一条探针命令，返回 `{结果文本, state}`。

  `state` 需含 `:status` / `:cid` / `:scene_ref` / `:voxel_worker`。
  """
  @spec run(String.t(), map()) :: {String.t(), map()}
  def run("voxel_rebind" <> _rest = command, state) do
    case parse_rebind(command) do
      {:ok, logical_scene_id, region_selector} ->
        result =
          SubscriptionWorker.rebind(
            state.voxel_worker,
            logical_scene_id,
            region_selector,
            :debug_probe
          )

        text =
          [
            "voxel_rebind=ok",
            "logical_scene_id=#{logical_scene_id}",
            "region_selector=#{region_selector}",
            "rebound_count=#{result.rebound_count}",
            "skipped_count=#{result.skipped_count}",
            "error_count=#{result.error_count}",
            Observe.voxel_debug_result("voxel_transport", state)
          ]
          |> Enum.join("\n")

        {text, state}

      {:error, reason} ->
        {"voxel_rebind=error\nreason=#{reason}", state}
    end
  end

  def run(command, state), do: {Observe.voxel_debug_result(command, state), state}

  defp parse_rebind(command) do
    case String.split(command, ~r/\s+/, trim: true) do
      ["voxel_rebind", logical_scene_id] ->
        with {:ok, logical_scene_id} <- parse_non_negative_integer(logical_scene_id) do
          {:ok, logical_scene_id, :all}
        end

      ["voxel_rebind", logical_scene_id, "all"] ->
        with {:ok, logical_scene_id} <- parse_non_negative_integer(logical_scene_id) do
          {:ok, logical_scene_id, :all}
        end

      ["voxel_rebind", logical_scene_id, region_id] ->
        with {:ok, logical_scene_id} <- parse_non_negative_integer(logical_scene_id),
             {:ok, region_id} <- parse_non_negative_integer(region_id) do
          {:ok, logical_scene_id, region_id}
        end

      _other ->
        {:error, :usage_voxel_rebind_logical_scene_id_region_id_or_all}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _other -> {:error, :invalid_integer}
    end
  end
end
