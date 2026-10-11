defmodule GateServer.Npc.Life.State do
  @moduledoc """
  NPC 自有心智的纯规则与派生行为，不查询世界、不持久化、不调用模型。

  输入消费 World 已排序的权威操作；状态全部使用 JSON 字符串键。关心格只是记忆，
  不作为当前几何真值。一次毁坏过程只评价首个 damage/destroy，同材料修复后重新计数。
  情绪按经过时间衰减，关系与谨慎不随时间恢复；各数值系数是本轮游戏设计参数。
  """
  @half_life_ms 120_000
  @emotion_threshold 0.1

  @doc "建立新的心智，以调用方提供的游标和时间为起点。"
  def new(cid, world_id, cursor, now_ms) do
    %{
      "cid" => cid,
      "world_id" => world_id,
      "cursor" => cursor,
      "last_at_ms" => now_ms,
      "emotions" => %{"anger" => 0.0, "gratitude" => 0.0},
      "traits" => %{"caution" => 0.2},
      "relationships" => %{},
      "concerns" => %{},
      "evidence" => %{"damage_count" => 0, "help_count" => 0, "anger" => nil, "gratitude" => nil}
    }
  end

  @doc "按权威顺序消费新操作，返回下一状态和可批量写入记忆的英文经历。重复序号不评价。"
  def advance(state, events, cursor, now_ms) do
    {state, episodes} =
      Enum.reduce(events, {state, []}, fn event, {state, episodes} ->
        if event.seq <= state["cursor"] do
          {state, episodes}
        else
          state = state |> view(event.at_ms) |> Map.put("cursor", event.seq)
          {state, episode} = appraise(state, event)
          {state, if(episode, do: [episode | episodes], else: episodes)}
        end
      end)

    {state |> Map.put("cursor", max(cursor, state["cursor"])) |> view(now_ms),
     Enum.reverse(episodes)}
  end

  @doc "按真实经过时间返回衰减视图；负时间差保持状态，不修改源状态或持久层。"
  def view(state, now_ms) do
    elapsed = max(0, now_ms - state["last_at_ms"])
    factor = :math.pow(0.5, elapsed / @half_life_ms)
    emotions = Map.new(state["emotions"], fn {name, value} -> {name, value * factor} end)
    %{state | "last_at_ms" => max(now_ms, state["last_at_ms"]), "emotions" => emotions}
  end

  @doc """
  从当前 Body 观察选择社交模式和期望距离，位置仅使用 observation 的完整 XYZ。

  活跃愤怒优先回避其可见来源，回避模式在已达安全距离后仍保留，防止工作动作走回伤害者。
  活跃感激接近其可见来源，到达后允许继续工作；其余角色过近时按谨慎与信任保持距离。
  返回 source_seq 指向规则依据，陌生人的初始谨慎没有来源序号。
  """
  def behavior(state, %{self: %{position: origin}, entities: entities}, now_ms) do
    state = view(state, now_ms)
    base = 2.0 + 6.0 * state["traits"]["caution"]

    candidates =
      entities
      |> Enum.reject(&(&1.entity_id == state["cid"]))
      |> Enum.map(fn entity ->
        relation = state["relationships"][to_string(entity.entity_id)]
        trust = if relation, do: relation["trust"], else: 0.0
        distance = max(1.0, base - 3.0 * trust)
        actual = distance(origin, entity.position)

        cond do
          source?(state, "anger", entity.entity_id) ->
            {0, -state["emotions"]["anger"], entity.entity_id,
             choice(
               :avoid,
               entity.entity_id,
               distance + 6.0 * state["emotions"]["anger"],
               state["evidence"]["anger"]["seq"]
             )}

          source?(state, "gratitude", entity.entity_id) ->
            desired = max(1.0, distance - 3.0 * state["emotions"]["gratitude"])
            mode = if actual > desired, do: :thank, else: :work

            {1, -state["emotions"]["gratitude"], entity.entity_id,
             choice(mode, entity.entity_id, desired, state["evidence"]["gratitude"]["seq"])}

          actual < distance ->
            {2, actual - distance, entity.entity_id,
             choice(:cautious, entity.entity_id, distance, distance_source(state, relation))}

          true ->
            {3, actual, entity.entity_id,
             choice(:work, entity.entity_id, distance, distance_source(state, relation))}
        end
      end)

    case Enum.sort(candidates) do
      [{_, _, _, choice} | _] -> choice
      [] -> choice(:work, nil, base, nil)
    end
  end

  defp choice(mode, actor, distance, seq),
    do: %{mode: mode, actor: actor, distance: distance, source_seq: seq}

  defp distance_source(state, relation) do
    caution = state["evidence"]["caution"]

    cond do
      relation != nil -> relation["source_seq"]
      caution != nil -> caution["seq"]
      true -> nil
    end
  end

  defp source?(state, emotion, actor) do
    state["emotions"][emotion] > @emotion_threshold and
      match?(%{"actor" => ^actor}, state["evidence"][emotion])
  end

  defp distance({x, y, z}, {ex, ey, ez}),
    do: :math.sqrt((x - ex) ** 2 + (y - ey) ** 2 + (z - ez) ** 2)

  defp appraise(state, event) do
    key = cell_key(event.cell)
    concern = state["concerns"][key]

    cond do
      event.kind == :build and concern != nil and concern["damaged"] and
          event.material == concern["material"] ->
        state = put_in(state, ["concerns", key, "damaged"], false)
        if event.actor == state["cid"], do: {state, nil}, else: react(state, event, :help)

      event.actor != state["cid"] and event.kind in [:damage, :destroy] and
        (event.placed_by == state["cid"] or concern != nil) and
          (concern == nil or not concern["damaged"]) ->
        concern = concern || %{"cell" => Tuple.to_list(event.cell), "material" => event.material}
        state = put_in(state, ["concerns", key], Map.put(concern, "damaged", true))
        react(state, event, :damage)

      true ->
        {state, nil}
    end
  end

  defp react(state, event, reaction) do
    {emotion, count_key, trust_change, drift} =
      case reaction do
        :damage -> {"anger", "damage_count", -0.35, 0.05}
        :help -> {"gratitude", "help_count", 0.25, -0.01}
      end

    count = state["evidence"][count_key] + 1
    actor_key = to_string(event.actor)
    previous = state["relationships"][actor_key]
    trust = if previous, do: previous["trust"], else: 0.0
    source = %{"actor" => event.actor, "seq" => event.seq}

    state =
      state
      |> put_in(["emotions", emotion], bound(state["emotions"][emotion] + 0.6, 0.0, 1.0))
      |> put_in(["evidence", count_key], count)
      |> put_in(["evidence", emotion], source)
      |> put_in(["relationships", actor_key], %{
        "trust" => bound(trust + trust_change, -1.0, 1.0),
        "source_seq" => event.seq
      })

    state =
      if count >= 3 do
        state
        |> put_in(["traits", "caution"], bound(state["traits"]["caution"] + drift, 0.0, 1.0))
        |> put_in(["evidence", "caution"], source)
      else
        state
      end

    verb = if reaction == :damage, do: "damaged", else: "repaired"
    feeling = if reaction == :damage, do: "angry", else: "grateful"
    {x, y, z} = event.cell

    episode = %{
      "id" => state["world_id"] <> ":" <> to_string(event.seq),
      "seq" => event.seq,
      "at_ms" => event.at_ms,
      "text" =>
        "At #{event.at_ms} ms, Actor #{event.actor} #{verb} construction I care about " <>
          "at (#{x}, #{y}, #{z}), material #{event.material}, in world #{state["world_id"]} " <>
          "(transaction #{event.seq}). I feel #{feeling} toward this actor; my trust changed."
    }

    {state, episode}
  end

  defp cell_key({x, y, z}), do: "#{x},#{y},#{z}"
  defp bound(value, low, high), do: min(high, max(low, value))
end
