defmodule GateServer.Npc.Life.State do
  @moduledoc """
  NPC 自有心智的纯规则与派生行为，不查询世界、不持久化、不调用模型。

  输入消费 World 已排序的权威操作；状态全部使用 JSON 字符串键。关心格只是记忆，
  不作为当前几何真值。一次毁坏过程只评价首个 damage/destroy，同材料修复后重新计数。
  情绪按经过时间衰减，关系与谨慎不随时间恢复；各数值系数是本轮游戏设计参数。
  canonical 状态只保留最近评价事件的情绪时刻锚，轮询时间不改锚。
  当前衰减值由 view/2 派生；观察不得回写，只有新评价接纳时先衰减再更新 canonical。
  """
  alias GateServer.Npc.Life.Emotions
  @emotion_threshold 0.1

  @doc "建立新的心智，以调用方提供的游标和时间为起点。"
  def new(cid, world_id, cursor, now_ms) do
    %{
      "cid" => cid,
      "world_id" => world_id,
      "cursor" => cursor,
      "last_at_ms" => now_ms,
      "emotions" => %{"anger" => 0.0, "gratitude" => 0.0},
      "traits" => %{"caution" => 0.2, "sociability" => 0.5},
      "relationships" => %{},
      "concerns" => %{},
      "evidence" => %{"damage_count" => 0, "help_count" => 0, "anger" => nil, "gratitude" => nil}
    }
  end

  @doc "升级旧合法持久心智：只补亲和初值，不重放旧事件，不推算历史增益。仅在加载边界调用。"
  def upgrade(state), do: update_in(state, ["traits"], &Map.put_new(&1, "sociability", 0.5))

  @doc """
  按权威顺序消费新操作，返回 canonical 事件态和可批量写入记忆的英文经历。
  重复序号不评价；情绪在事件时刻衰减与饱和，消费分批方式不影响结果。
  每条经历直接标注权威 at_ms 对应的 UTC ISO8601 毫秒时刻，原始事件身份与时间不变。
  now_ms 保留调用接口，但轮询时刻不写回事件锚；当前情绪请读取 view(state, now_ms)。
  """
  def advance(state, events, cursor, _now_ms, emotion_owner \\ :rules) do
    {state, episodes} =
      Enum.reduce(events, {state, []}, fn event, {state, episodes} ->
        if event.seq <= state["cursor"] do
          {state, episodes}
        else
          state = Map.put(state, "cursor", event.seq)
          {state, episode} = appraise(state, event, emotion_owner)
          {state, if(episode, do: [episode | episodes], else: episodes)}
        end
      end)

    {Map.put(state, "cursor", max(cursor, state["cursor"])), Enum.reverse(episodes)}
  end

  @doc "按真实经过时间返回衰减视图；负时间差不倒流。纯观察不回写；接纳新评价时用它作为更新起点。"
  def view(%{"feelings" => _} = state, now_ms), do: Emotions.view(state, now_ms)

  def view(state, now_ms) do
    elapsed = max(0, now_ms - state["last_at_ms"])

    emotions =
      Map.new(state["emotions"], fn {name, value} -> {name, Emotions.decay(value, elapsed)} end)

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
            desired =
              max(
                1.0,
                distance -
                  3.0 * state["emotions"]["gratitude"] * (0.5 + state["traits"]["sociability"])
              )

            mode = if actual > desired, do: :thank, else: :work
            priority = if mode == :thank, do: 1, else: 3

            {priority, -state["emotions"]["gratitude"], entity.entity_id,
             Map.put(
               choice(mode, entity.entity_id, desired, state["evidence"]["gratitude"]["seq"]),
               :acknowledge,
               mode == :work
             )}

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
    do: %{mode: mode, actor: actor, distance: distance, source_seq: seq, acknowledge: false}

  defp distance_source(state, relation) do
    caution = state["evidence"]["caution"]

    cond do
      relation != nil -> relation["source_seq"]
      caution != nil -> caution["seq"]
      true -> nil
    end
  end

  defp source?(state, emotion, actor) do
    # 兼容 Social 只消费 World 规则来源；模型评价有独立序号，不参与旧感谢确认。
    state["emotions"][emotion] > @emotion_threshold and
      match?(%{"actor" => ^actor}, state["evidence"][emotion]) and
      state["evidence"][emotion]["kind"] != "appraisal"
  end

  defp distance({x, y, z}, {ex, ey, ez}),
    do: :math.sqrt((x - ex) ** 2 + (y - ey) ** 2 + (z - ez) ** 2)

  defp appraise(state, event, emotion_owner) do
    key = cell_key(event.cell)
    concern = state["concerns"][key]

    cond do
      event.kind == :build and concern != nil and concern["damaged"] and
          event.material == concern["material"] ->
        state = put_in(state, ["concerns", key, "damaged"], false)

        if event.actor == state["cid"],
          do: {state, nil},
          else: react(state, event, :help, emotion_owner)

      event.actor != state["cid"] and event.kind in [:damage, :destroy] and
        (event.placed_by == state["cid"] or concern != nil) and
          (concern == nil or not concern["damaged"]) ->
        concern = concern || %{"cell" => Tuple.to_list(event.cell), "material" => event.material}
        state = put_in(state, ["concerns", key], Map.put(concern, "damaged", true))
        react(state, event, :damage, emotion_owner)

      true ->
        {state, nil}
    end
  end

  defp react(state, event, reaction, emotion_owner) do
    state = if emotion_owner == :model, do: state, else: view(state, event.at_ms)

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

    # 模型 Life 的情绪只由 Appraisal 接纳；旧 Social 保留建设规则，关系与人格仍独立评价。
    state =
      if emotion_owner == :model,
        do: state,
        else:
          state
          |> put_in(["emotions", emotion], bound(state["emotions"][emotion] + 0.6, 0.0, 1.0))
          |> put_in(["evidence", emotion], source)

    state =
      state
      |> put_in(["evidence", count_key], count)
      |> put_in(["relationships", actor_key], %{
        "trust" => bound(trust + trust_change, -1.0, 1.0),
        "source_seq" => event.seq
      })

    state =
      if count >= 3 do
        state
        |> put_in(["traits", "caution"], bound(state["traits"]["caution"] + drift, 0.0, 1.0))
        |> put_in(["evidence", "caution"], source)
        |> put_in(
          ["traits", "sociability"],
          bound(
            state["traits"]["sociability"] + if(reaction == :help, do: 0.05, else: -0.01),
            0.0,
            1.0
          )
        )
        |> put_in(["evidence", "sociability"], source)
      else
        state
      end

    verb = if reaction == :damage, do: "damaged", else: "repaired"
    feeling = if reaction == :damage, do: "angry", else: "grateful"
    {x, y, z} = event.cell
    at_utc = event.at_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    episode = %{
      "id" => state["world_id"] <> ":" <> to_string(event.seq),
      "seq" => event.seq,
      "at_ms" => event.at_ms,
      "actor" => event.actor,
      "text" =>
        "At #{at_utc} (UTC), Actor #{event.actor} #{verb} construction I care about " <>
          "at (#{x}, #{y}, #{z}), material #{event.material}, in world #{state["world_id"]} " <>
          "(transaction #{event.seq}). " <>
          if(emotion_owner == :model,
            do: "My trust changed; emotional appraisal is pending.",
            else: "I feel #{feeling} toward this actor; my trust changed."
          )
    }

    {state, episode}
  end

  defp cell_key({x, y, z}), do: "#{x},#{y},#{z}"
  defp bound(value, low, high), do: min(high, max(low, value))
end
