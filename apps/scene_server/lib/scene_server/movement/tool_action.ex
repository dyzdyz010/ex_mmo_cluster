defmodule SceneServer.Movement.ToolAction do
  @moduledoc "Global system：现有 Gate 请求 worker 的工具编排。Player 授权身份，World 判遮挡和频率，目标 Player 唯一提交 Body。"
  alias SceneServer.Movement.{Player, Scene, ToolHit}
  alias VoxelRegion.World

  @doc "经当前角色 owner 登记后执行一次；重复请求读原结果。"
  def run(player, identity, world, request, ingress) do
    case Player.authorize_tool(player, identity, request, ingress) do
      {:ok, actor} ->
        result =
          if request.granularity == 5,
            do: body_tool(world, actor, request),
            else: World.tool_intent(world, actor, request)

        if request.action == 0,
          do: result,
          else: Player.finish_tool(player, actor.action_key, result)

      {:done, result} ->
        result

      error ->
        error
    end
  end

  defp body_tool(world, actor, request) do
    {target_id, 0} = request.owner

    with {:ok, tool} <- World.tool_definition(world, request.tool_id),
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
         true <- ToolHit.permitted?(target.scope, actor.position, target.position),
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

        case Player.receive_hit(target.player, hit) do
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

  @doc "把同一 Body 提交回执编码给双方；identity 仅决定接收会话，来源身份字段保持一致。"
  def message(receipt, identity, request_id) do
    struct!(
      MmoContracts.Session.ToolState,
      Map.drop(receipt, [:body])
      |> Map.merge(%{
        identity: identity,
        request_id: request_id,
        part: to_string(receipt.part),
        life: receipt.body.life,
        recoverable: receipt.body.recoverable
      })
    )
  end
end
