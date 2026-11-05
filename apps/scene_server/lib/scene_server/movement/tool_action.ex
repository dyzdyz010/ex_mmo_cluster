defmodule SceneServer.Movement.ToolAction do
  @moduledoc """
  Global system：角色工具编排，只由 `SceneServer.Movement.Intent` 调用（玩家 Gate 编辑 worker 与 NPC Body 共用）。
  Player 授权身份，World 判遮挡和频率，目标 Player 唯一提交 Body。
  """
  alias SceneServer.Movement.{Harm, Player, Scene, ToolHit}
  alias VoxelRegion.World
  require Logger

  @doc "经当前角色 owner 登记后执行一次；重复请求读原结果。调用方只有 `SceneServer.Movement.Intent.run/3`。"
  def run(player, identity, world, request, ingress) do
    case Player.authorize_tool(player, identity, request, ingress) do
      {:ok, actor} ->
        result = case request.granularity do
          5 -> body_tool(world, actor, request)
          6 -> area_tool(world, actor, request)
          _ -> World.tool_intent(world, actor, request)
        end

        if request.action == 0,
          do: result,
          else: Player.finish_tool(player, actor.action_key, result)

      {:done, result} ->
        result

      error ->
        error
    end
  end

  # 战斗招式（g=6）：World 复核朝向、频率与遮挡并选出受击人物（单体段一个、范围段全部）；
  # 区内无人＝打空（已接纳）；区内有人但全部被拒＝首个拒绝原因。战斗关闭直接拒绝，不消耗频率。
  defp area_tool(world, actor, request) do
    with {:ok, tool} <- World.tool_definition(world, request.tool_id),
         %{} = impact <- tool["body_impact"],
         {:ok, players} <- Scene.tool_candidates(actor.scene) do
      targets = for player <- players, player != actor.player,
        {:ok, target} <- [Player.hit_context(player)], target.status != :dead,
        do: target
      case World.tool_intent(world, Map.put(actor, :area_targets, targets), request) do
        {:area, seq, targets} ->
          {receipts, errors} = Enum.reduce(targets, {[], []}, fn {target, part}, {receipts, errors} ->
            result = Player.receive_effect(target.player, %{
              key: actor.action_key, actor: actor, target: target, part: part,
              request_id: request.request_id, impact: %{
                depth: impact["depth"], protein_g: impact["protein_g"], heal_s: impact["heal_s"]}})
            case result do
              {:ok, receipt} -> {[receipt | receipts], errors}
              {:error, reason} ->
                Logger.info("area_body_target request_id=#{request.request_id} target=#{target.id} result=#{reason}")
                {receipts, [reason | errors]}
            end
          end)
          if receipts == [] and errors != [],
            do: {:error, List.last(errors)},
            else: {:area, seq, Enum.reverse(receipts)}
        error -> error
      end
    else
      nil -> {:error, :unsupported_body_tool}
      :error -> {:error, :invalid_tool}
      {:error, _} = error -> error
    end
  end

  defp body_tool(world, actor, request) do
    {target_id, 0} = request.owner

    with {:ok, tool} <- World.tool_definition(world, request.tool_id),
         # 只有精确工具经人物射线攻击；战斗招式一律走 g=6 判定区。探测（action 0）任何工具照旧。
         true <- request.action == 0 or Map.get(tool, "target_mode", "precise") == "precise",
         %{} = impact <- tool["body_impact"],
         {:ok, players} <- Scene.tool_candidates(actor.scene),
         {:ok, target, distance, part} <-
           nearest(
             players,
             actor,
             request.direction,
             tool["range_macro"],
             if(request.action == 0, do: target_id, else: nil)
           ),
         true <- target.id == target_id,
         true <- Harm.permitted?(target.scope, actor.position, target.position),
         true <- request.action == 0 or target.life_generation == request.incarnation,
         :ok <- World.body_tool(world, actor, request, distance) do
      if request.action == 0 do
        {:body,
         %{
           source_id: 0,
           source_session: 0,
           source_life: 0,
           action_seq: 0,
           target_id: target.id,
           target_life: target.life_generation,
           part: part,
           body: target.body
         }}
      else
        hit = %{
          key: actor.action_key,
          actor: actor,
          target: target,
          part: part,
          request_id: request.request_id,
          impact: %{
            depth: impact["depth"],
            protein_g: impact["protein_g"],
            heal_s: impact["heal_s"]
          }
        }

        case Player.receive_effect(target.player, hit) do
          {:ok, receipt} -> {:body, receipt}
          error -> error
        end
      end
    else
      nil -> {:error, :unsupported_body_tool}
      :error -> {:error, :invalid_tool}
      false -> {:error, :stale_or_forbidden_target}
      {:error, _} = error -> error
    end
  end

  defp nearest(players, actor, direction, range, body_for) do
    # 仅请求时查看本场成员；没有每帧扫描，也没有从可视缓存推断命中。
    hits =
      for player <- players,
          player != actor.player,
          {:ok, target} <- [Player.hit_context(player, body_for)],
          target.status != :dead,
          {:ok, distance, part} <- [
            ToolHit.ray(actor.eye, direction, target.position, target.profile, range)
          ],
          do: {distance, target.id, target, part}

    case Enum.min(hits, fn -> nil end) do
      nil -> {:error, :no_target}
      {distance, _, target, part} -> {:ok, target, distance, part}
    end
  end

  @doc """
  身体回执的公开投影（纯数据）：来源 / 目标身份、动作序号、部位（字符串）与目标的生命、可恢复生命，
  不含完整身体报告。玩家下行的 ToolState 与 NPC 的 Outcome data 都用这一份。
  """
  def public_receipt(receipt) do
    Map.drop(receipt, [:body])
    |> Map.merge(%{
      part: to_string(receipt.part),
      life: receipt.body.life,
      recoverable: receipt.body.recoverable
    })
  end

  @doc "把同一 Body 提交回执编码给双方；identity 仅决定接收会话，来源身份字段保持一致。"
  def message(receipt, identity, request_id) do
    struct!(
      MmoContracts.Session.ToolState,
      Map.merge(public_receipt(receipt), %{identity: identity, request_id: request_id})
    )
  end
end
