defmodule WorldServer.Movement.Projectile do
  @moduledoc "全局系统功能：投射物查询/身体交付的组合边界，经显式 Scene 路由访问当前 Player；不持有拟态或身体真值。"
  alias SceneServer.Movement.{Player, Scene, ToolHit}
  alias VoxelRegion.Magic.Semblance

  @doc "在 World 异步工作中逐次采当前 owner；位置只归属这一实际采样时刻。"
  def poll(shots, _cv) do
    Enum.map(shots, fn {id, s} ->
      result = case s do
        %{impact_delivery: hit} -> {:delivered, deliver(hit)}
        _ -> sample(s)
      end
      {id, s.age_s, result}
    end)
  end

  defp contexts(scene_id) do
    with {:ok, route} <- WorldServer.Movement.route(scene_id),
         {:ok, players} <- Scene.tool_candidates(route.scene_ref) do
      for player <- players, {:ok, context} <- [Player.hit_context(player)], do: context
    else
      {:error, _} -> []
    end
  end

  defp sample(s) do
    source = s.projectile_source
    targets = contexts(source.identity.scene_id)
    now = System.system_time(:microsecond)
    age = min(max(s.age_s, (now - s.t0_us) / 1.0e6), s.lifetime_s)
    actor = Enum.find(targets, &(&1.id == source.cid and &1.identity == source.identity and &1.life_generation == source.life_generation and &1.status != :dead))
    hits = if actor do
      for {t0, t1, a, b} <- Semblance.flight_segments(s, age),
          target <- targets, target.id != source.cid, target.status != :dead,
          ToolHit.permitted?(target.scope, actor.position, target.position),
          {:ok, t} <- [ToolHit.sweep(a, b, s.radius_m, target.position, target.profile)],
          do: {(t0 + (t1 - t0) * t - s.age_s) / (age - s.age_s), target}
    else
      []
    end
    hit = Enum.min_by(hits, fn {t, target} -> {t, target.id} end, fn -> nil end)
    actor = if actor, do: Map.put(source, :position, actor.position), else: source
    {:sample, age, actor, hit, now}
  end

  @doc "持久目标只按原角色重新找当前 owner；Player 复核会话/生命，已经接纳的重投返回原收据。"
  def deliver(hit) do
    case WorldServer.Movement.character_owner(hit.target.id) do
      nil -> {:retry, :target_unavailable}
      target ->
        case Player.receive_projectile(target.player, hit) do
          {:error, :invalid_state} -> {:retry, :target_unavailable}
          result -> result
        end
    end
  end

  @doc "最终 World 事务之后向双方当前匹配生命/会话发送相同收据。"
  def notify(hit, seq) do
    for {id, identity, life} <- [{hit.actor.cid, hit.actor.identity, hit.actor.life_generation},
          {hit.target.id, hit.target.identity, hit.target.life_generation}] do
      with {:ok, route} <- WorldServer.Movement.route(identity.scene_id) do
        send(route.scene_ref, {:projectile_receipt, id, identity, life, hit, seq})
      end
    end
    :ok
  end
end
