defmodule NpcServer.Life.Emotions do
  @moduledoc """
  对象化情绪的唯一数值与时间规则。canonical 只保存 feelings；主要情绪与来源在读取时派生。
  对象与触发来源独立，人物按身份合并，无人物评价按事件区分。合并取衰减后值与新值的最大值。
  """
  alias NpcServer.Life.EmotionVocabulary
  @half_life_ms 120_000

  @doc "沿用游戏半衰期；负时间不倒流。"
  def decay(value, elapsed), do: value * :math.pow(0.5, max(0, elapsed) / @half_life_ms)

  @doc "在加载边界迁移旧单对象状态；缺失来源显式保留 legacy 身份，不推测人物。"
  def migrate(state) do
    feelings =
      for {emotion, intensity} <- state["emotions"], intensity > 0 do
        evidence = state["evidence"][emotion]

        object =
          cond do
            evidence && is_integer(evidence["actor"]) ->
              %{"kind" => "actor", "id" => evidence["actor"]}

            evidence && evidence["kind"] == "appraisal" && is_integer(evidence["seq"]) ->
              %{"kind" => "event", "id" => evidence["seq"]}

            true ->
              %{"kind" => "legacy", "id" => emotion}
          end

        %{
          "emotion" => emotion,
          "object" => object,
          "intensity" => intensity,
          "at_ms" => state["last_at_ms"],
          "evidence" => evidence
        }
      end

    state |> Map.put("feelings", ordered(feelings)) |> canonical()
  end

  @doc "接纳一项已校验评价；只更新相同类别与对象，弱刺激不替换仍较强的来源。"
  def put(state, entry, source, now_ms) do
    object =
      if entry["target_id"] == nil,
        do: %{"kind" => "event", "id" => entry["source_seq"]},
        else: %{"kind" => "actor", "id" => entry["target_id"]}

    key = {entry["emotion"], object}
    old = Enum.find(state["feelings"], &({&1["emotion"], &1["object"]} == key))
    at_ms = if old, do: max(now_ms, old["at_ms"]), else: now_ms

    if old && decay(old["intensity"], at_ms - old["at_ms"]) > entry["intensity"] do
      state
    else
      feeling = %{
        "emotion" => entry["emotion"],
        "object" => object,
        "intensity" => entry["intensity"],
        "at_ms" => at_ms,
        "evidence" => %{
          "actor" => entry["target_id"],
          "seq" => entry["source_seq"],
          "kind" => "appraisal",
          "reason" => entry["reason"],
          "source" => source
        }
      }

      others = Enum.reject(state["feelings"], &({&1["emotion"], &1["object"]} == key))
      Map.put(state, "feelings", ordered([feeling | others]))
    end
  end

  @doc "派生各对象当前值和主要情绪；不改变 canonical 时间锚，不将人物间强度相加。"
  def view(state, now_ms) do
    feelings =
      Enum.map(state["feelings"], fn feeling ->
        feeling
        |> Map.put("intensity", decay(feeling["intensity"], now_ms - feeling["at_ms"]))
        |> Map.put("at_ms", max(now_ms, feeling["at_ms"]))
      end)

    initial = Map.new(EmotionVocabulary.names(), &{&1, 0.0})

    {emotions, evidence} =
      Enum.reduce(
        feelings,
        {initial, Map.drop(state["evidence"], EmotionVocabulary.names())},
        fn f, {values, evidence} ->
          name = f["emotion"]

          if f["intensity"] > Map.get(values, name, 0.0),
            do: {Map.put(values, name, f["intensity"]), Map.put(evidence, name, f["evidence"])},
            else: {values, evidence}
        end
      )

    state
    |> Map.put("feelings", feelings)
    |> Map.put("emotions", emotions)
    |> Map.put("evidence", evidence)
  end

  defp canonical(state),
    do:
      state
      |> Map.delete("emotions")
      |> Map.update!("evidence", &Map.drop(&1, EmotionVocabulary.names()))

  defp ordered(feelings), do: Enum.sort_by(feelings, &{&1["emotion"], &1["object"]})
end
