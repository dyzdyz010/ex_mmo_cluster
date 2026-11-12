defmodule NpcServer.Life.State do
  @moduledoc """
  NPC 自有心智的纯规则与派生行为，不查询世界、不持久化、不调用模型。

  输入消费 World 已排序的权威操作；状态全部使用 JSON 字符串键。关心格只是记忆，
  不作为当前几何真值。一次毁坏过程只评价首个 damage/destroy，同材料修复后重新计数；评价过之后整座有名字的建筑
  被移除时，不再评价情绪与信任，但照样写出“整座没了”的经历（不带情绪句）。整座有名字的建筑被移除后，被移除的那一格的
  关心格删除：之后别人在这里放东西不是修那座建筑。

  经历原文按下面的**标准描述表**写（唯一定义处 `account/4`）：每种 World 事件对应一句固定的英文，不同事件不共用一个词。
  事件带 `building`（被动那一格所属 prefab 的发布名，由 Life 向 World 查好写进事件；散格、没有名字的定义都没有）时
  按建筑细分，并把名字记在关心格上，之后别人修这一格（修上去的是散格，事件自己不带建筑）仍说得出修的是哪座。
  整句 = `At <UTC> (UTC), ` + 原文 + 情绪句（规则模式 `I feel angry / grateful toward this actor; my trust changed.`，
  模型评价模式 `My trust changed; emotional appraisal is pending.`）；`<where>` =
  `(x, y, z), material <m>, in world <world> (transaction <seq>)`：

  | 种类 | 事件 | 原文 |
  |---|---|---|
  | `:removed` | 有名字的建筑被 `:destroy` 且根实例已不在（事件的 `instance_removed`） | `Actor <cid> removed the entire building "<名>" that I built, at <where>; the building no longer exists.` |
  | `:broken` | 有名字的建筑被 `:destroy`，根实例还在 | `Actor <cid> broke off part of the building "<名>" that I built, at <where>; the rest of the building is still standing.` |
  | `:damaged` | 有名字的建筑被 `:damage`（打了没毁） | `Actor <cid> damaged part of the building "<名>" that I built, at <where>; the building is still standing.` |
  | `:repaired` | 别人在有名字的建筑受损的那一格修上同一材料 | `Actor <cid> repaired the damaged part of the building "<名>" that I built, at <where>.` |
  | `:damaged_unnamed` | 没有名字（散格、空名发布）被 `:damage` / `:destroy` | `Actor <cid> damaged construction I care about at <where>.` |
  | `:repaired_unnamed` | 没有名字的那一格被别人修好 | `Actor <cid> repaired construction I care about at <where>.` |

  `:removed`、`:damaged` 是离线对照实测过的原文（docs/10-active/cross-cutting/tools/jev/s1c_diag.py 的 `WHOLE_ALT`、`PART`）。
  给模型选择的是名字与“还在 / 没了”：坐标、材料号、事务号留着不碍事，但只有它们时模型认不出是哪座建筑
  （对照见 docs/10-active/cross-cutting/tools/jev/README.md 的 2026-11-12 两节）。

  `"buildings"` 记“我放下的有名字的建筑”（自己的 prefab 放置事件）：`[%{"name", "instance" => [birth, occurrence],
  "anchor" => [x, y, z] 锚点所在宏格}]`，按放下的次序，同一锚点只留最新的一座。这只是记忆：此刻在不在由发问时现查
  World 回答（`NpcServer.Life.mind/2`），不在这里推断。
  情绪按经过时间衰减，关系与谨慎不随时间恢复；各数值系数是本轮游戏设计参数。
  canonical 状态只保留最近评价事件的情绪时刻锚，轮询时间不改锚。
  当前衰减值由 view/2 派生；观察不得回写，只有新评价接纳时先衰减再更新 canonical。
  """
  alias NpcServer.Life.Emotions
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
      "buildings" => [],
      "evidence" => %{"damage_count" => 0, "help_count" => 0, "anger" => nil, "gratitude" => nil}
    }
  end

  @doc """
  升级旧合法持久心智：只补亲和初值与空的“我的建筑”表，不重放旧事件，不推算历史增益（升级前放下的建筑不补记）。
  仅在加载边界调用。
  """
  def upgrade(state),
    do: state |> update_in(["traits"], &Map.put_new(&1, "sociability", 0.5)) |> Map.put_new("buildings", [])

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
  给心智快照的只读投影（规则模式的状态）：此刻仍活跃的情绪，各带来源角色与衰减后的强度，
  `[%{emotion: "anger" | "gratitude", actor: cid, intensity: 0.1..1.0}]`，固定按 anger、gratitude 的次序。
  衰减到阈值（0.1，与 `behavior/3` 判定“活跃”同一个值）及以下的不出现。纯观察，不回写。
  """
  def feelings(state, now_ms) do
    state = view(state, now_ms)

    for emotion <- ["anger", "gratitude"],
        intensity = state["emotions"][emotion],
        intensity > @emotion_threshold,
        do: %{emotion: emotion, actor: state["evidence"][emotion]["actor"], intensity: intensity}
  end

  @doc "给心智快照的只读投影：对各角色的信任 `[%{actor: cid, trust: -1.0..1.0}]`，按角色 id 排列（关系表以角色为键，没有别的次序）。"
  def relationships(state) do
    state["relationships"]
    |> Enum.map(fn {actor, relation} -> %{actor: String.to_integer(actor), trust: relation["trust"]} end)
    |> Enum.sort_by(& &1.actor)
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
    state = remember_building(state, event)
    key = cell_key(event.cell)
    concern = state["concerns"][key]

    cond do
      event.kind == :build and concern != nil and concern["damaged"] and
          event.material == concern["material"] ->
        state = put_in(state, ["concerns", key, "damaged"], false)

        if event.actor == state["cid"],
          do: {state, nil},
          else: react(state, event, :help, concern["building"], emotion_owner)

      event.actor != state["cid"] and event.kind in [:damage, :destroy] and
        (event.placed_by == state["cid"] or concern != nil) and
          (concern == nil or not concern["damaged"]) ->
        concern = concern || new_concern(event)

        # 整座有名字的建筑被移除：它不在了，这一格上关于它的关心随之结束（之后别人在这里放东西不是修它）。
        state =
          if what(:damage, event, concern["building"]) == :removed,
            do: Map.update!(state, "concerns", &Map.delete(&1, key)),
            else: put_in(state, ["concerns", key], Map.put(concern, "damaged", true))

        react(state, event, :damage, concern["building"], emotion_owner)

      # 这一格已在这次毁坏过程里评价过（先被打过一下），之后整座有名字的建筑被移除：情绪与信任不再评价一次
      # （数值规则仍是“一次毁坏过程只评价首个”），但“整座没了”这条经历照样写出；没有发生评价，所以不带情绪句。
      # 关心格同样随这座建筑结束。
      event.actor != state["cid"] and event.kind == :destroy and event[:instance_removed] == true and
        concern != nil and concern["damaged"] and concern["building"] != nil ->
        state = Map.update!(state, "concerns", &Map.delete(&1, key))
        {state, episode(state, event, account(:removed, event, concern["building"], state["world_id"]))}

      true ->
        {state, nil}
    end
  end

  # 我放下的有名字的建筑（自己的 prefab 放置事件，Life 已按 `prefab` 查好发布名写进 `building`）：记下名字、根实例与
  # 锚点所在宏格，按放下的次序。这是记忆——此刻在不在只由发问时现查 World 回答（`NpcServer.Life.mind/2`）。
  # 同一锚点同时只能有一座，所以在同一锚点重建时新的一座取代旧的那条。
  defp remember_building(state, %{kind: :build, building: name, instance: {_, _} = instance, anchor: {_, _, _} = anchor} = event)
       when is_binary(name) do
    if event.actor == state["cid"] do
      anchor = Tuple.to_list(anchor)
      kept = Enum.reject(state["buildings"], &(&1["anchor"] == anchor))
      %{state | "buildings" => kept ++ [%{"name" => name, "instance" => Tuple.to_list(instance), "anchor" => anchor}]}
    else
      state
    end
  end

  defp remember_building(state, _event), do: state

  # 新的关心格；所属建筑有名字才记 "building"（旧持久行与散格的关心格都没有这个键）。
  defp new_concern(event) do
    concern = %{"cell" => Tuple.to_list(event.cell), "material" => event.material}
    if event[:building], do: Map.put(concern, "building", event[:building]), else: concern
  end

  # building：关心格上记的建筑名字，没有为 nil。
  defp react(state, event, reaction, building, emotion_owner) do
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

    feeling = if reaction == :damage, do: "angry", else: "grateful"

    tail =
      if emotion_owner == :model,
        do: "My trust changed; emotional appraisal is pending.",
        else: "I feel #{feeling} toward this actor; my trust changed."

    {state, episode(state, event, account(what(reaction, event, building), event, building, state["world_id"]) <> " " <> tail)}
  end

  # 这件事属于标准描述表里的哪一种。有名字的建筑才细分；没有名字（散格、空名发布）照旧只分破坏与修好。
  defp what(:help, _event, nil), do: :repaired_unnamed
  defp what(:help, _event, _building), do: :repaired
  defp what(:damage, _event, nil), do: :damaged_unnamed
  defp what(:damage, %{kind: :damage}, _building), do: :damaged
  defp what(:damage, %{kind: :destroy} = event, _building),
    do: if(event[:instance_removed] == true, do: :removed, else: :broken)

  defp account(what, event, name, world) do
    {x, y, z} = event.cell
    a = event.actor
    where = "(#{x}, #{y}, #{z}), material #{event.material}, in world #{world} (transaction #{event.seq})"

    case what do
      :removed -> ~s|Actor #{a} removed the entire building "#{name}" that I built, at #{where}; the building no longer exists.|
      :broken -> ~s|Actor #{a} broke off part of the building "#{name}" that I built, at #{where}; the rest of the building is still standing.|
      :damaged -> ~s|Actor #{a} damaged part of the building "#{name}" that I built, at #{where}; the building is still standing.|
      :repaired -> ~s|Actor #{a} repaired the damaged part of the building "#{name}" that I built, at #{where}.|
      :damaged_unnamed -> "Actor #{a} damaged construction I care about at #{where}."
      :repaired_unnamed -> "Actor #{a} repaired construction I care about at #{where}."
    end
  end

  # 一条经历：句首标权威时刻，身份与时间取自事件。
  defp episode(state, event, text) do
    at_utc = event.at_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    %{
      "id" => state["world_id"] <> ":" <> to_string(event.seq),
      "seq" => event.seq,
      "at_ms" => event.at_ms,
      "actor" => event.actor,
      "text" => "At #{at_utc} (UTC), " <> text
    }
  end

  defp cell_key({x, y, z}), do: "#{x},#{y},#{z}"
  defp bound(value, low, high), do: min(high, max(low, value))
end
