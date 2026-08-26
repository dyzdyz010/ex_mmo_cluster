defmodule GateServer.Session.Observe do
  @moduledoc """
  Gate 会话的**结构化观测字段**构造 —— CLI / 日志调试面的唯一字段来源。

  这里只做「把运行时对象摊平成可读字段」，不做任何业务判断，也不决定事件名与前缀
  （事件名由调用方给出，传输前缀由 `GateServer.Session.Sink` 负责）。下行 payload
  在这里被**解码回结构化字段**，让调试面不必对着裸字节猜。

  解码失败一律降级为 `%{decode_error: reason}`：观测路径不能因为一帧编码异常而影响
  业务链路，但也不能假装成功——错误原因必须出现在字段里。
  """

  alias GateServer.Voxel.SubscriptionWorker

  @doc """
  把上行消息摘要成 observe 字段。

  auth_request 只记 username 与 `token_redacted?`，凭据本身永不入日志。
  未特化的消息类型原样返回，保留现场。
  """
  @spec message_summary(term()) :: term()
  def message_summary({:auth_request, username, _token, request_id}) do
    %{type: :auth_request, username: username, request_id: request_id, token_redacted?: true}
  end

  def message_summary({:movement_input, frame}) do
    %{type: :movement_input, seq: frame.seq, client_tick: frame.client_tick}
  end

  def message_summary({:voxel_debug_probe, %{request_id: request_id, command: command}}) do
    %{type: :voxel_debug_probe, request_id: request_id, command: command}
  end

  def message_summary({:voxel_impact_intent, request}) do
    %{
      type: :voxel_impact_intent,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      impact_kind: request.impact_kind
    }
  end

  def message_summary(message), do: message

  @doc """
  `0x6E VoxelDebugProbe` 的应答文本（`key=value` 逐行）。

  `state` 需含 `:status` / `:cid` / `:scene_ref` / `:voxel_worker`。订阅集是 worker
  的权威状态，这里同步问它，不在连接侧另存一份可能漂移的副本。
  """
  @spec voxel_debug_result(String.t(), map()) :: String.t()
  def voxel_debug_result("voxel_transport", state) do
    subscriptions = SubscriptionWorker.subscriptions(state.voxel_worker)

    [
      "voxel_sync=server-authoritative",
      "voxel_truth_source=server",
      "connection_status=#{state.status}",
      "cid=#{state.cid}",
      "scene_attached=#{not is_nil(state.scene_ref)}",
      "voxel_subscription_count=#{map_size(subscriptions)}",
      "voxel_subscriptions=#{inspect(subscriptions |> Map.keys() |> Enum.take(16))}",
      "voxel_subscription_routes=#{inspect(subscription_debug(subscriptions))}",
      "confirmed_chunk_versions={}",
      "inflight_intent_count=0",
      "voxel_codec_endian=big",
      "micro_resolution=8"
    ]
    |> Enum.join("\n")
  end

  def voxel_debug_result(command, state) do
    [
      "command=#{command}",
      "connection_status=#{state.status}",
      "voxel_debug=unknown_command"
    ]
    |> Enum.join("\n")
  end

  @doc "订阅集的路由摘要（最多 16 条）。"
  @spec subscription_debug(map()) :: [map()]
  def subscription_debug(subscriptions) do
    subscriptions
    |> Map.values()
    |> Enum.take(16)
    |> Enum.map(fn subscription ->
      Map.take(subscription, [
        :logical_scene_id,
        :chunk_coord,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch,
        :scene_node
      ])
    end)
  end

  @doc "把下行 `0x62 ChunkSnapshot` payload 解码成 observe 字段。"
  @spec chunk_snapshot_fields(binary()) :: map()
  def chunk_snapshot_fields(payload) do
    case SceneServer.Voxel.Codec.decode_chunk_snapshot_payload(payload) do
      {:ok, %{request_id: request_id, storage: storage}} ->
        %{
          request_id: request_id,
          logical_scene_id: storage.logical_scene_id,
          chunk_coord: storage.chunk_coord,
          chunk_version: storage.chunk_version,
          normal_blocks: length(storage.normal_blocks),
          refined_cells: length(storage.refined_cells)
        }

      {:error, reason} ->
        %{decode_error: reason}
    end
  end

  @doc "把下行 `0x63 ChunkDelta` payload 解码成 observe 字段。"
  @spec chunk_delta_fields(binary()) :: map()
  def chunk_delta_fields(payload) do
    case SceneServer.Voxel.Codec.decode_chunk_delta_payload(payload) do
      {:ok, delta} ->
        %{
          logical_scene_id: delta.logical_scene_id,
          chunk_coord: delta.chunk_coord,
          base_chunk_version: delta.base_chunk_version,
          new_chunk_version: delta.new_chunk_version,
          op_count: length(delta.ops),
          ops_sample: Enum.take(delta.ops, 4) |> Enum.map(&delta_op_summary/1)
        }

      {:error, reason} ->
        %{decode_error: reason}
    end
  end

  defp delta_op_summary(op) do
    %{
      delta_kind: Map.get(op, :delta_kind),
      macro_index: Map.get(op, :macro_index),
      cell_version: Map.get(op, :cell_version),
      cell_hash: Map.get(op, :cell_hash),
      payload_bytes: byte_size_or_zero(Map.get(op, :payload))
    }
  end

  defp byte_size_or_zero(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_zero(_value), do: 0
end
