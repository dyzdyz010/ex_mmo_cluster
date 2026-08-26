defmodule GateServer.Voxel.SubscribeIntent do
  @moduledoc """
  体素订阅意图（0x61 / ChunkInvalidate）在 Gate 侧的**唯一**适配层。

  订阅集的所有者是 per-connection 的 `GateServer.Voxel.SubscriptionWorker`：连接进程
  只把整框意图投给它，由 worker 在自身权威集上做差集并异步 route + subscribe。本模块
  负责意图的入口校验、投递与结构化 observe，让 tcp / ws 两条链路共用同一份语义。

  成功路径**不发**结果帧——快照即 ACK（worker 以本连接为 subscriber 订阅，快照经
  fan-out 直达出口）；路由 / 订阅失败由 worker 回 `{:voxel_subscribe_failed, ...}`，
  再由连接进程编成 `0x68`。
  """

  alias GateServer.Session.Sink
  alias GateServer.Voxel.SubscriptionWorker

  # 半径上限（L∞，单位 chunk）：一次整框订阅最多 21³ chunk，防止单个客户端用超大框
  # 把 Scene 侧路由打满。超限显式拒绝，不静默截断。
  @max_radius 10

  @doc "订阅半径上限（L∞，单位 chunk）。"
  @spec max_radius() :: pos_integer()
  def max_radius, do: @max_radius

  @doc "校验订阅半径。"
  @spec validate_radius(term()) :: :ok | {:error, :voxel_subscribe_radius_too_large}
  def validate_radius(radius)
      when is_integer(radius) and radius >= 0 and radius <= @max_radius,
      do: :ok

  def validate_radius(_radius), do: {:error, :voxel_subscribe_radius_too_large}

  @doc """
  把整框订阅意图投给 worker，并记录结构化 observe。

  `ctx` 需含 `:cid` 与 `:sink`（见 `GateServer.Session.Sink`）。
  """
  @spec reconcile(pid(), map(), %{cid: integer(), sink: Sink.t()}) :: :ok
  def reconcile(worker, request, %{sink: sink} = ctx) do
    known_versions = known_versions(Map.get(request, :known, []))

    SubscriptionWorker.reconcile(worker, %{
      request_id: request.request_id,
      client_intent_seq: Map.get(request, :client_intent_seq, 0),
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk,
      radius: request.radius_l_inf,
      want_snapshot: request.want_snapshot,
      known: known_versions
    })

    Sink.emit(sink, "voxel_chunk_subscribe_dispatched", %{
      connection_pid: self(),
      cid: ctx.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk,
      radius: request.radius_l_inf,
      want_snapshot: request.want_snapshot,
      known_count: map_size(known_versions),
      known_sample:
        known_versions
        |> Enum.take(8)
        |> Enum.map(fn {coord, version} ->
          %{chunk_coord: coord, chunk_version: version}
        end)
    })

    :ok
  end

  @doc """
  处理 ChunkInvalidate：把受影响 chunk 从 worker 订阅集移除。

  阶段4 评审 F5：不移除的话，客户端重订会被 worker 的差集当成「已订阅」吞掉，
  scene 侧订阅再也建不回来。解不开的失效帧退化为清空整张 route 缓存（宁可多重路由，
  不能留下指向旧 owner 的陈旧路由）。
  """
  @spec invalidate(pid(), binary()) :: term()
  def invalidate(worker, payload) do
    case SceneServer.Voxel.Codec.decode_chunk_invalidate_payload(payload) do
      {:ok, %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}} ->
        SubscriptionWorker.invalidate_chunk(worker, logical_scene_id, chunk_coord)

      _other ->
        SubscriptionWorker.invalidate_route_cache(worker)
    end
  end

  @doc "把客户端上报的 known 列表归一成 `chunk_coord => chunk_version` 映射。"
  @spec known_versions([map()]) :: %{tuple() => non_neg_integer()}
  def known_versions(known) do
    Map.new(known, fn %{chunk_coord: chunk_coord, chunk_version: chunk_version} ->
      {chunk_coord, chunk_version}
    end)
  end

  @doc "observe 用的 known 采样（最多 8 条，避免日志被整框版本表淹没）。"
  @spec known_sample(map()) :: [map()]
  def known_sample(request) do
    request
    |> Map.get(:known, [])
    |> Enum.take(8)
    |> Enum.map(fn %{chunk_coord: chunk_coord, chunk_version: chunk_version} ->
      %{chunk_coord: chunk_coord, chunk_version: chunk_version}
    end)
  end
end
