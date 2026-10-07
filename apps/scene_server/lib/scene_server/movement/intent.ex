defmodule SceneServer.Movement.Intent do
  @moduledoc """
  全局系统功能：角色世界意图的唯一执行入口（Voxim `Docs/Combat-Action-Design.md` §1 薄 Action 层的服务端接纳点；
  §11 第 1 步的 ActionId 与结果阶段统一将来挂在这里，本模块不交付）。

  玩家的 Gate 编辑 worker（`GateServer.Session.Dispatch`）与 NPC Body 的 FIFO worker 交来与
  `MmoContracts.Voxel.Codec.decode/1` 同形的 `{kind, request}`：角色 owner 接纳（工具走 `ToolAction.run/5` 的
  `authorize_tool`，其余走 `Player.tool_context/2`）→ World 公共 API → 原样结果。
  无进程、无状态；不校验形状、不翻译 reason、不重试、不捕获退出。生产 action 0（只读余额）不经此处。

  返回的第二项是“调用方是否补发余额”的唯一规则：工具 action ∈ [1, 2] 且 granularity ≠ 5（与结果无关）；
  生产、附件、prefab 放 / 拆 / 换在 `tool_context` 接纳通过时（与 World 结果无关）；发布不补。
  调用方先发回执、再补余额。设计见 docs/10-active/cross-cutting/2026-10-07-character-capability-library.md §7。

  例外：NPC `design_house` 技能的发布仍直接调 `SceneServer.PrefabDesigner.publish/3`（死亡门与施法门经
  `World.publish_prefab` 内的 `actor.refresh` 生效，设计稿 §7.7），不经本模块，也没有 `character_intent` 行。
  NPC Body 在进本模块之前拒绝的命令（类型守卫、位置未知、编辑盒越界）记 `npc_intent_rejected`。
  """
  require Logger
  alias SceneServer.Movement.{Player, ToolAction}
  alias VoxelRegion.World

  @type kind ::
          :voxel_tool_intent
          | :voxel_production_intent
          | :voxel_attachment_intent
          | :voxel_prefab_place_v1
          | :voxel_prefab_remove_v1
          | :voxel_prefab_replace_v1
          | :voxel_prefab_publish_v1
  @type session :: %{
          required(:player) => pid(),
          required(:identity) => term(),
          required(:world_ref) => GenServer.server(),
          optional(atom()) => term()
        }
  @type ingress :: %{optional(:received_us) => integer(), optional(:clock_node) => node()}
  @type result ::
          {:ok, non_neg_integer()}
          | {:ok, map()}
          | {:ok, <<_::256>>}
          | {:body, map()}
          | {:error, term()}

  @prefab [:voxel_prefab_place_v1, :voxel_prefab_remove_v1, :voxel_prefab_replace_v1]

  @doc "执行一条已校验的世界意图；返回原样结果与是否补发余额。ingress 是意图到达角色入口的时刻，并进 actor。"
  @spec run(session(), {kind(), map()}, ingress()) :: {result(), boolean()}
  def run(session, {kind, request}, ingress) do
    started = System.monotonic_time(:microsecond)
    {result, refresh} = execute(session, kind, request, ingress)

    # 三类入口（玩家、NPC、技能经 Body）共用的一行；夹具可能缺 cid / client_intent_seq，按 Map.get 读。
    # action / tool / g 区分同一 kind 下的动作（挖掘与拆解、放置与进食、人物探测与命中）；prefab 与发布没有这些字段，留空。
    Logger.info(
      "character_intent kind=#{kind} cid=#{Map.get(session, :cid)} client_seq=#{Map.get(request, :client_intent_seq, 0)} request_id=#{request.request_id} elapsed_us=#{System.monotonic_time(:microsecond) - started} action=#{Map.get(request, :action)} tool=#{Map.get(request, :tool_id)} g=#{Map.get(request, :granularity)} result=#{summary(result)}"
    )

    {result, refresh}
  end

  defp execute(session, :voxel_tool_intent, request, ingress) do
    result =
      ToolAction.run(session.player, session.identity, session.world_ref, request, ingress)

    {result, request.action in [1, 2] and request.granularity != 5}
  end

  defp execute(session, kind, request, ingress) do
    case Player.tool_context(session.player, session.identity) do
      {:ok, actor} ->
        actor = Map.merge(actor, ingress)
        {world_call(session.world_ref, actor, kind, request), kind != :voxel_prefab_publish_v1}

      error ->
        {error, false}
    end
  end

  defp world_call(world, actor, :voxel_production_intent, request),
    do: World.production_intent(world, actor, request)

  defp world_call(world, actor, :voxel_attachment_intent, request),
    do: World.attachment_intent(world, actor, request)

  defp world_call(world, actor, kind, request) when kind in @prefab,
    do: World.prefab_intent(world, actor, kind, request)

  defp world_call(world, actor, :voxel_prefab_publish_v1, request),
    do: World.publish_prefab(world, actor, request.definition, request.name)

  defp summary({:ok, seq}) when is_integer(seq), do: "ok seq=#{seq}"
  defp summary({:ok, _}), do: "ok"
  defp summary({:body, receipt}), do: "body target=#{receipt.target_id}"
  defp summary({:error, reason}), do: "error reason=#{inspect(reason)}"
end
