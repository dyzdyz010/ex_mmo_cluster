defmodule GateServer.Voxel.ResultFrame do
  @moduledoc """
  `0x68 VoxelIntentResult` 回执帧的**唯一**构造入口。

  所有体素上行意图（impact / edit / surface element / field conduct / prefab /
  build reservation / 订阅失败）都用同一种回执帧答复客户端。拆分前这套构造在
  `tcp_connection` 与 `ws_connection` 各有一份拷贝，其中 `edit_ok/2` 的
  `authoritative` 透传修复（2026-06-27 幽灵块根因）只打在 TCP 一侧，WS 一直返回空
  列表 —— 正是镜像复制导致的单边漂移。共享后回执语义只有一个 owner。

  帧里的 `authoritative` 字段只在**成功**路径携带被编辑宏格的当前权威态；拒绝路径
  一律为 `[]`（拒绝不携带格态）。
  """

  @type request :: map()

  @doc """
  通用拒绝回执。

  `reason` 会 `inspect/1` 成可诊断字符串下行，不做归一化——客户端与 CLI 都依赖原始
  reason 区分业务级拒绝。
  """
  @spec error(request(), term()) :: tuple()
  def error(request, reason) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: :rejected,
       result_ref: 0,
       authoritative: [],
       reason: inspect(reason)
     }}
  end

  @doc "撞击意图（0x64）成功回执，`result_ref` 取写入后的 chunk_version。"
  @spec impact_ok(request(), map()) :: tuple()
  def impact_ok(request, result) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: result.chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  @doc """
  编辑 / 表面元件意图成功回执。

  显式契约（2026-06-27 幽灵块根因修复）：透传 ChunkProcess 返回的被编辑 macro 当前
  权威态。no-op 编辑也带（`authoritative` 为空列表），让客户端据此清掉本地幽灵块。
  """
  @spec edit_ok(request(), map()) :: tuple()
  def edit_ok(request, result) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: result.chunk_version,
       authoritative: Map.get(result, :authoritative, []),
       reason: "ok"
     }}
  end

  @doc """
  编辑 / 表面元件意图拒绝回执。

  `:stale_chunk_version` 与 `:stale_cell_hash` 来自
  `ChunkProcess.validate_intent_preconditions/2`，映射到协议的 `Stale`(3) 码；其余
  一律 `Rejected`(2)，让客户端能区分"版本过期需重取"与"业务拒绝"。
  """
  @spec edit_error(request(), term()) :: tuple()
  def edit_error(request, reason) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: edit_result_code(reason),
       result_ref: 0,
       authoritative: [],
       reason: inspect(reason)
     }}
  end

  defp edit_result_code(:stale_chunk_version), do: :stale
  defp edit_result_code(:stale_cell_hash), do: :stale
  defp edit_result_code(_reason), do: :rejected

  @doc "场域导通意图（0x75）成功回执，`result_ref` 取建立的 region_id。"
  @spec field_conduct_ok(request(), map()) :: tuple()
  def field_conduct_ok(request, summary) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: Map.get(summary, :region_id) || 0,
       authoritative: [],
       reason: "field_conduct_ok"
     }}
  end

  @doc "prefab 放置（0x67）成功回执，`result_ref` 取覆盖 chunk 的最大版本号。"
  @spec prefab_ok(request(), map()) :: tuple()
  def prefab_ok(request, summary) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: summary.max_chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  @doc """
  占位式接受回执 —— 仅供 build-reservation 意图在真实预约管线落地前使用。

  帧形状与最终规格一致，客户端今天就能 round-trip。
  """
  @spec stub_accepted(request()) :: tuple()
  def stub_accepted(request) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: 0,
       authoritative: [],
       reason: ""
     }}
  end
end
