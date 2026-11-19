# S1-R9 栏文本生成：对 S1-R8 里过了产品检查的 23 份真实规划应答，走产品路径生成 `Plans and promises` 栏。
#
# 是什么
#   规格：.demo/observe/npc-slice1-20261112/s1r9/plan.md（唯一规格）、exec-brief.md。对每个样本：
#     DayPlan.check/3（词表 = s1r7/export/request-template.json 的六个候选名，各是一个静态种类、没有对象：
#       `%{名 => %{}}`，稿 A 批 0b 的形状；此刻分钟 = 该基准 state 自己 `Now:` 一行的钟点）
#       -> DayPlan.adopt/6（固定日号 @day，at_ms 任意）
#       -> DayPlan.column/3（P：各意图 done 0，状态由代码按基准钟点推）
#       -> 产品 Mind 的同一渲染得到栏正文
#     PD：同 P，但对第一条意图的活动（`{种类, nil}`，静态种类没有对象）调 DayPlan.record_activity/4 恰好 times 次（钟点同上）再取栏。
#   不连库、不起节点：只用纯函数。运行（WSL，apps/npc_server 下）：
#     .demo/observe/npc-slice1-20261112/s1r8/impl/run-nodb.sh <日志名> run --no-start <本脚本路径>
#   输出：.demo/observe/npc-slice1-20261112/s1r9/columns/columns.json
#
# 渲染（同 Mind.plans/2）
#   Mind.plans/2 是私有函数。栏正文的拼法在这里逐字照它写（见 render_body/1）：
#       names = State.names(observation)（本脚本的观察桩没有角色，为 %{}；意图都没点名，用不上）
#       lines = Enum.map(intents, &Mind.plan_intent_line(&1, names)) ++ Enum.map(wants, &"I would like to #{&1["want"]}, but I cannot do that yet")
#       body  = Enum.join(lines, "\n")；栏 = [{"Plans and promises", body}]；整行文本 = Mind.text(栏)
#   自检：对每个样本，用 Mind.snapshot/4 的真实调用（最小的 profile / observation / life 桩，只让计划栏有内容）产出的
#   `Plans and promises` 栏，必须与上面拼出来的逐字相同；同时断言 snapshot 里该栏的位置在 Current situation 之前、
#   没有反思栏时紧接在 What I remember 之后。
#
# 读数之外的判断一概不做：check/3 不过的样本只记录（by 不晚于此刻 = 钟点原因；别的原因立刻停）。

alias NpcServer.Life.{DayPlan, State}
alias NpcServer.Mind

defmodule S1R9Columns do
  @day 1
  @title "Plans and promises"

  # 基准 state 的时间戳（s1r7b_why.py 的 GIVEN）；Now 一行取自这些真实 state 文件，不是 S1-R8 材料的钟点。
  @bases %{
    "M1f" => "20261114T164642.383Z",
    "M2f" => "20261114T165419.917Z",
    "M3f" => "20261114T170543.917Z",
    "M5f" => "20261114T171721.514Z",
    "M7f" => "20261114T173241.273Z",
    "M7s" => "20261114T173250.335Z",
    "MVa" => "20261114T171039.721Z",
    "MVb" => "20261114T171258.830Z"
  }
  @base_order ["M1f", "M2f", "M3f", "M5f", "M7f", "M7s", "MVa", "MVb"]

  # 轮 -> 基准（同 R7c）：R1->M1f；R2->M2f；R3->M3f、MVa；R4->MVb；R5->M5f；R7->M7f、M7s
  @round_bases [
    {1, ["M1f"]},
    {2, ["M2f"]},
    {3, ["M3f", "MVa"]},
    {4, ["MVb"]},
    {5, ["M5f"]},
    {7, ["M7f", "M7s"]}
  ]

  def run do
    repo = Path.expand("../..", File.cwd!())
    root = Path.join(repo, ".demo/observe/npc-slice1-20261112")
    r8 = Path.join(root, "s1r8")
    out_dir = Path.join(root, "s1r9/columns")
    File.mkdir_p!(out_dir)

    names = vocabulary(Path.join(root, "s1r7/export/request-template.json"))
    # check/3 的词表：每个候选名是一个静态种类（没有对象可点名）。
    kinds = Map.new(names, &{&1, %{}})
    clocks = base_clocks(Path.join(root, "s1r7/states"))
    rows = read_json(Path.join(r8, "results.json"))["rows"] |> Map.new(&{&1["name"], &1})

    samples =
      for {round, bases} <- @round_bases,
          rep <- 1..3,
          row <- [Map.fetch!(rows, "R#{round}-r#{rep}")],
          row["checks"]["all_pass"] == true,
          base <- bases,
          do: {base, round, rep, row}

    if length(samples) != 23, do: halt_with("样本数 #{length(samples)} != 23")

    results =
      Enum.map(samples, fn {base, round, rep, row} ->
        sample(base, round, rep, row, kinds, clocks[base], r8)
      end)

    ok = for {:ok, name, entry} <- results, do: {name, entry}
    failed = for {:check_failed, entry} <- results, do: entry

    self_checked = Enum.map(ok, fn {_name, entry} -> entry["self_check"] end)

    output = %{
      "day" => @day,
      "vocabulary" => names,
      "base_clocks" => Map.new(@base_order, &{&1, clock_json(clocks[&1])}),
      "samples" => Map.new(ok),
      "sample_order" => for({name, _} <- ok, do: name),
      "check_failed" => failed,
      "self_check" => %{
        "samples_checked" => length(self_checked),
        "all_identical" => Enum.all?(self_checked, & &1)
      }
    }

    File.write!(Path.join(out_dir, "columns.json"), Jason.encode!(output, pretty: true))

    IO.puts("samples=#{length(samples)} ok=#{length(ok)} check_failed=#{length(failed)}")

    IO.puts(
      "self_check: Mind.snapshot/4 的栏与本脚本拼的栏逐字相同的样本 #{Enum.count(self_checked, & &1)} / #{length(self_checked)}"
    )

    for f <- failed do
      IO.puts(
        "  check 不过 #{f["sample"]}: #{f["error"]} 此刻 #{f["now"]} 意图 by #{inspect(f["bys"])}"
      )
    end
  end

  defp sample(base, round, rep, row, kinds, clock, r8) do
    name = "#{base}_r#{rep}"
    text = response_text(Path.join(r8, "raw/#{row["raw_file"]}"))
    now = clock.minute

    case DayPlan.check(text, kinds, now) do
      {:ok, checked} ->
        {:ok, name, build(name, base, round, rep, checked, clock)}

      {:error, {:by_not_after_now, _by} = reason} ->
        {:check_failed,
         %{
           "sample" => name,
           "base" => base,
           "round" => round,
           "repeat" => rep,
           "error" => inspect(reason),
           "now" => hh_mm(now),
           "bys" => by_list(text)
         }}

      {:error, reason} ->
        halt_with("#{name} 的 check/3 不过（不是钟点原因）：#{inspect(reason)}")
    end
  end

  defp build(name, base, round, rep, checked, clock) do
    now = clock.minute
    plan = DayPlan.adopt(DayPlan.new(), @day, now, checked, :day, 0)
    [first | _] = plan["intents"]
    a1 = first["activity"]
    times = first["times"]

    plan_done =
      Enum.reduce(1..times, plan, fn _, acc ->
        DayPlan.record_activity(acc, {a1, nil}, @day, now)
      end)

    p = DayPlan.column(plan, @day, now)
    pd = DayPlan.column(plan_done, @day, now)

    p_line = Mind.text([{@title, render_body(p)}])
    pd_line = Mind.text([{@title, render_body(pd)}])

    checks = [snapshot_check(p, p_line, clock), snapshot_check(pd, pd_line, clock)]

    %{
      "sample" => name,
      "base" => base,
      "round" => round,
      "repeat" => rep,
      "now" => hh_mm(now),
      "A1" => a1,
      "A1_times" => times,
      "P" => p_line,
      "PD" => pd_line,
      "intents" => Enum.map(plan["intents"], &intent_json/1),
      "wants" => length(plan["wants"]),
      "P_column" => Enum.map(p.intents, &column_json/1),
      "PD_column" => Enum.map(pd.intents, &column_json/1),
      "A1_first_intent_done_in_PD" => hd(pd.intents).done,
      "self_check" => Enum.all?(checks)
    }
  end

  # 同 Mind.plans/2：意图行（plan_intent_line/2，名字取自观察桩：没有角色，为 %{}）在前，wants 行在后，换行连起来。
  defp render_body(%{intents: intents, wants: wants}) do
    names = State.names(observation(0))

    lines =
      Enum.map(intents, &Mind.plan_intent_line(&1, names)) ++
        Enum.map(wants, &"I would like to #{&1["want"]}, but I cannot do that yet")

    Enum.join(lines, "\n")
  end

  # 自检：Mind.snapshot/4 的真实调用，栏与逐字拼的相同、位置在 What I remember 之后（无反思栏）、Current situation 之前。
  defp snapshot_check(column, line, clock) do
    sections = Mind.snapshot(profile(), observation(clock.minute), [], life(column))
    titles = Enum.map(sections, &elem(&1, 0))
    {_, body} = List.keyfind(sections, @title, 0)
    i = Enum.find_index(titles, &(&1 == @title))

    Mind.text([{@title, body}]) == line and
      Enum.at(titles, i - 1) == "What I remember" and
      Enum.at(titles, i + 1) == "Current situation"
  end

  defp profile, do: %{who: "Garen, a builder", persona: %{traits: [], personal: ""}}

  defp observation(minute) do
    %{
      world_time: %{minute_of_day: minute, day: 1},
      entities: [],
      self: %{entity_id: 1, position: {0.0, 0.0, 0.0}, body_state: nil},
      balances: nil
    }
  end

  defp life(column) do
    %{
      feelings: [],
      relationships: [],
      recent: [],
      now_ms: 0,
      models: [],
      memories: [],
      thought: nil,
      plan: column,
      buildings: []
    }
  end

  defp vocabulary(path) do
    for c <- read_json(path)["candidates"], do: c["name"]
  end

  # 基准 state 文件第一行 `Now: It is <时段>, HH:MM.` 的钟点。
  defp base_clocks(dir) do
    Map.new(@bases, fn {label, stamp} ->
      first = dir |> Path.join("asked-#{stamp}.txt") |> File.read!() |> String.split("\n") |> hd()

      [_, hh, mm] = Regex.run(~r/^Now: It is \w+, (\d\d):(\d\d)\.$/, first)
      {label, %{hh_mm: "#{hh}:#{mm}", minute: String.to_integer(hh) * 60 + String.to_integer(mm)}}
    end)
  end

  defp clock_json(%{hh_mm: hh_mm, minute: minute}), do: %{"hh_mm" => hh_mm, "minute" => minute}

  # 产品 Writer.read/1：stop_reason 必须是 end_turn，text 块按次序连起来。
  defp response_text(path) do
    js = read_json(path)
    "end_turn" = js["stop_reason"]

    for(%{"type" => "text", "text" => t} <- js["content"], do: t) |> Enum.join()
  end

  defp by_list(text) do
    case Jason.decode(text) do
      {:ok, %{"intents" => intents}} -> for(i <- intents, do: i["by"])
      _ -> []
    end
  end

  defp intent_json(i),
    do: %{
      "id" => i["id"],
      "activity" => i["activity"],
      "times" => i["times"],
      "by" => i["by"],
      "done" => i["done"]
    }

  defp column_json(c),
    do: %{
      "activity" => c.activity,
      "times" => c.times,
      "done" => c.done,
      "by" => c.by,
      "status" => Atom.to_string(c.status)
    }

  defp hh_mm(minute) do
    pad = &(&1 |> Integer.to_string() |> String.pad_leading(2, "0"))
    "#{pad.(div(minute, 60))}:#{pad.(rem(minute, 60))}"
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp halt_with(message) do
    IO.puts("STOP: #{message}")
    System.halt(2)
  end
end

S1R9Columns.run()
