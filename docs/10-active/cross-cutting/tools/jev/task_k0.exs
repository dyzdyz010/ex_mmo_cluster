# K-0（任务层离线探索）：用**当前产品代码**渲染每日回顾与任务推进的请求、用产品的 `Tasks.check/3` 判应答。
#
# 是什么
#   规格是 `.demo/observe/npc-task-k0-20261119/plan.md`（发问前写定）。本脚本只做 Elixir 侧的事，发请求由同目录的
#   `task_k0_replay.py` 做（key 只进那个 Python 进程）：
#     render-review   每份 S1-R8 材料渲染一次回顾请求，写 `<out>/requests/review/<材料>.json` 与发送次序 `manifest.json`；
#     judge-review    读 `<out>/raw/review/` 与 `<out>/sent-review.json`，逐份经 `Tasks.check/3`（{:review, …}）判，写 `results-review.json`；
#     render-advance  按 plan.md 的选取规则，从**合法**的回顾应答里取任务、从结局池取真实结局，渲染推进请求到 `requests/advance/`；
#                     可选第三个参数是推进条数上限（复测用，如 `retest-1/plan.md` 的 6），缺省 = 40 − 回顾实际发出数；
#     judge-advance   读 `raw/advance/` 与 `sent-advance.json`，逐份经 `Tasks.check/3`（:advance）判，写 `results-advance.json`，
#                     再合并两段、按 plan.md 的规则算 Q1–Q6，写 `results.json`。
#
# 为什么这样取
#   - 回顾的系统提示词：产品 `DayPlan.Prompt.review_system_prompt/2`；词表：`Offers.plan_kinds/1`（按生成器次序：S1-R7 六个
#     候选 + `speak_to` + `eat` + `craft`；K-0 时另含 `look_for`，复测 1 起按产品现状不含；T-2 加 `look_for` 时再立任务词表入口），
#     对象按 Life 起规划槽的展开（Life 的私有 `vocabulary/2`，这里用同样的公开函数 `State.person/2` 组合）。人与名字的来源同
#     S1-R8b（`s1r8b_0b.exs` 的 `@people` 注释）：关系表只有 Corvin；R1 观察里有 Corvin，R2–R7 没人。
#   - 回顾的用户消息：S1-R8 真实材料拆回 `materials`（同 S1-R8b 拆法）交产品 `Prompt.user_message/1`，断言与 S1-R8 字节相同。
#   - 推进：任务是回顾应答经 `Tasks.check/3` 检查后的结果（对象已换成 `%{"actor" => cid}`），结局只取 plan.md 结局池里的真实结局；
#     系统提示词与用户消息由产品 `Tasks.Prompt` 渲染。
#
# 怎么运行（WSL；经 `.demo/observe/npc-task-k0-20261119/mix.sh`，在 apps/npc_server 下）
#   mix run --no-start <本文件> render-review <out>   ……   mix run --no-start <本文件> judge-advance <out>
# 不连库、不起节点、不发网络请求。

defmodule TaskK0 do
  alias NpcServer.Life.DayPlan.Prompt
  alias NpcServer.Life.State
  alias NpcServer.Life.Tasks
  alias NpcServer.Life.Tasks.Prompt, as: TaskPrompt
  alias NpcServer.Offers

  @root Path.expand("../../../../..", __DIR__)
  @s1r8 Path.join(@root, ".demo/observe/npc-slice1-20261112/s1r8")
  @fixtures Path.join(@root, "apps/npc_server/test/support/fixtures")

  @materials ["R1", "R2", "R3", "R4", "R5", "R7"]
  @attempts 3
  @corvin 1_906_495_721_474
  @others %{"R1" => [%{entity_id: @corvin, name: "Corvin"}]}
  @relationships [@corvin]

  # 请求总数硬上限（plan.md）。
  @cap 40
  # 产品写作超时：`NpcServer.Http` 的缺省 60 s。
  @product_timeout_ms 60_000

  # 结局池（plan.md“推进”一节；Selector 历史 `Recent activities` 里的真实结局，每个种类至多一种失败）。
  @failures %{
    "build_hut" => {"build", "insufficient_material"},
    "gather_stone" => {"gather", "exhausted"}
  }
  @completed MapSet.new(~w(build_hut gather_stone gather_limestone guard_hut visit_plaza confront_wrecker speak_to))

  def main(["render-review", out]), do: render_review(out)
  def main(["judge-review", out]), do: judge_review(out)
  def main(["render-advance", out]), do: render_advance(out, nil)
  def main(["render-advance", out, limit]), do: render_advance(out, String.to_integer(limit))
  def main(["judge-advance", out]), do: judge_advance(out)

  # ---------------------------------------------------------------- 回顾

  defp render_review(out) do
    dir = Path.join([out, "requests", "review"])
    File.mkdir_p!(dir)

    for name <- @materials do
      request = s1r8_request(name)
      character = character(request)
      materials = materials(request)
      {now, now_minute, day} = clock(hd(materials.right_now))
      vocabulary = vocabulary(name)
      system = Prompt.review_system_prompt(character, vocabulary)
      user = Prompt.user_message(materials)

      true = user == user_of(request) || raise "#{name}: 用户消息与 S1-R8 不同"

      record = %{
        "material" => name,
        "now" => now,
        "now_minute" => now_minute,
        "day" => day,
        "character" => character,
        "names" => names(name),
        "system" => system,
        "user" => user,
        "vocabulary" => encode_vocabulary(vocabulary),
        "checks" => %{"user_equals_s1r8" => true}
      }

      File.write!(Path.join(dir, "#{name}.json"), Jason.encode!(record, pretty: true))

      IO.puts(
        "render #{name} now=#{now} system_chars=#{String.length(system)} user_chars=#{String.length(user)} " <>
          "kinds=#{Enum.map_join(vocabulary, ",", & &1.kind)} " <>
          "speak_to_objects=#{inspect(Map.keys(Enum.find(vocabulary, &(&1.kind == "speak_to")).objects))}"
      )
    end

    calls =
      for k <- 1..@attempts, m <- @materials, do: %{"id" => "#{m}-r#{k}", "request" => m}

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"calls" => calls}, pretty: true))
    IO.puts("manifest review: #{length(calls)} 次")
  end

  defp judge_review(out) do
    sent = read_json(Path.join(out, "sent-review.json"))

    rows =
      for call <- sent["calls"] do
        request = read_json(Path.join([out, "requests", "review", "#{call["request"]}.json"]))
        vocabulary = check_vocabulary(request["vocabulary"])
        question = {:review, request["now_minute"], []}
        judge_call(out, "review", call, fn text -> Tasks.check(text, vocabulary, question) end, &review_reading(&1, &2, vocabulary, request))
      end

    summary = review_summary(rows)

    write_json(Path.join(out, "results-review.json"), %{
      "judge" => "task_k0.exs judge-review（产品 Tasks.check/3 {:review, now_minute, []}）",
      "summary" => summary,
      "rows" => rows
    })

    for row <- rows, do: IO.puts("#{row["id"]} #{row["product_result"]} #{inspect(Map.delete(row["reading"] || %{}, "items"))}")
    IO.puts(Jason.encode!(summary, pretty: true))
  end

  # 回顾的读数：整份结果里开的任务与点名 Corvin 的步骤；条目级（每条意图 / 每个任务单独交 `Tasks.check/3`）；种类使用次数。
  defp review_reading(text, checked, vocabulary, request) do
    decoded = decoded(text)
    now = request["now_minute"]

    items =
      case decoded do
        %{} = answer ->
          intents =
            for intent <- List.wrap(answer["intents"]),
                do: item(Jason.encode!(%{"intents" => [intent], "cannot_yet" => [], "tasks" => %{"open" => [], "drop" => []}}), vocabulary, now)

          tasks =
            for task <- tasks_open(answer),
                do: item(Jason.encode!(%{"intents" => [], "cannot_yet" => [], "tasks" => %{"open" => [task], "drop" => []}}), vocabulary, now)

          %{"intents" => intents, "tasks" => tasks}

        _ ->
          nil
      end

    opened = if checked, do: checked.tasks.open, else: []

    %{
      "tasks_opened" => length(opened),
      "corvin_tasks" => Enum.count(opened, &corvin_task?/1),
      "corvin_step_kinds" => for(t <- opened, corvin_task?(t), do: Enum.map(t["steps"], &step_label/1)),
      "cannot_yet_corvin" => count_corvin(decoded && List.wrap(decoded["cannot_yet"])),
      "cannot_yet_total" => length(list_or_empty(decoded && decoded["cannot_yet"])),
      "kind_uses" => kind_uses(decoded),
      "named" => named(decoded, vocabulary),
      "items" => items
    }
  end

  # 应答原文里每个非 null 的 `object`（意图与任务步，不经检查）：落在哪、种类、原值，以及按词表归的类——
  # `listed`（该种类列出的名字）/ `static_kind`（种类没有名单，值却是词表里列出的名字；K-0 Q1 落空的那种）/
  # `outside_list`（值不是词表里任何一个名字，如只在记忆里出现的人）/ `unknown_kind`（种类不在词表）。
  defp named(nil, _vocabulary), do: []

  defp named(answer, vocabulary) do
    listed = vocabulary |> Map.values() |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

    entries =
      for(i <- list_or_empty(answer["intents"]), is_map(i), do: {"intent", i}) ++
        for t <- tasks_open(answer),
            is_map(t),
            s <- list_or_empty(t["steps"]),
            is_map(s),
            do: {"step", s}

    for {where, entry} <- entries, entry["object"] != nil do
      kind = entry["activity"]
      object = entry["object"]

      class =
        case Map.fetch(vocabulary, kind) do
          :error -> "unknown_kind"
          {:ok, names} when is_map_key(names, object) -> "listed"
          {:ok, _names} -> if MapSet.member?(listed, object), do: "static_kind", else: "outside_list"
        end

      %{"where" => where, "kind" => kind, "object" => object, "class" => class}
    end
  end

  defp item(json, vocabulary, now) do
    case Tasks.check(json, vocabulary, {:review, now, []}) do
      {:ok, _} -> "ok"
      {:error, reason} -> inspect(reason)
    end
  end

  # ---------------------------------------------------------------- 推进

  defp render_advance(out, given_limit) do
    review = read_json(Path.join(out, "results-review.json"))
    sent_review = read_json(Path.join(out, "sent-review.json"))
    review_sent = Enum.count(sent_review["calls"], &sent?/1)
    limit = min(given_limit || @cap, @cap - review_sent)

    # 1. 按回顾的发送次序，合法应答里每个新开的任务。
    tasks =
      for row <- review["rows"],
          row["product_result"] == ":ok",
          {task, index} <- Enum.with_index(row["checked"]["tasks"]["open"], 1) do
        request = read_json(Path.join([out, "requests", "review", "#{row["request"]}.json"]))
        siblings = List.delete(row["checked"]["tasks"]["open"], task)
        %{source: row["id"], index: index, request: request, task: task, others: siblings}
      end

    # 2–3. 情形：先所有 F、再所有 D、再所有 S；取前 limit 个。
    scenarios =
      (Enum.flat_map(tasks, &failed_case/1) ++
         Enum.flat_map(tasks, &done_case/1) ++ Enum.map(tasks, &stalled_case/1))
      |> Enum.take(limit)

    dir = Path.join([out, "requests", "advance"])
    File.mkdir_p!(dir)

    calls =
      for {scenario, n} <- Enum.with_index(scenarios, 1) do
        id = "A#{String.pad_leading(Integer.to_string(n), 2, "0")}"
        render_one(dir, id, scenario)
        %{"id" => id, "request" => id}
      end

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"calls" => calls}, pretty: true))

    IO.puts(
      "tasks=#{length(tasks)} review_sent=#{review_sent} limit=#{limit} advance=#{length(calls)} " <>
        "cases=#{inspect(Enum.frequencies(Enum.map(scenarios, & &1.case)))}"
    )
  end

  defp failed_case(%{task: %{"steps" => [head | _]}} = t) do
    case Map.fetch(@failures, head["kind"]) do
      {:ok, {act, reason}} ->
        log = [%{"kind" => head["kind"], "object" => head["object"], "outcome" => "failed", "act" => act, "reason" => reason}]
        [Map.merge(t, %{case: "F", log: log, steps: t.task["steps"], waiting: "failed"})]

      :error ->
        []
    end
  end

  defp done_case(%{task: %{"steps" => steps}} = t) do
    if Enum.all?(steps, &MapSet.member?(@completed, &1["kind"])) do
      log = for s <- steps, do: %{"kind" => s["kind"], "object" => s["object"], "outcome" => "completed"}
      [Map.merge(t, %{case: "D", log: log, steps: [], waiting: "steps_done"})]
    else
      []
    end
  end

  defp stalled_case(t), do: Map.merge(t, %{case: "S", log: [], steps: t.task["steps"], waiting: "stalled"})

  defp render_one(dir, id, s) do
    request = s.request
    day = request["day"]
    names = for {cid, name} <- request["names"], into: %{}, do: {String.to_integer(cid), name}
    vocabulary = runtime_vocabulary(request["vocabulary"])

    task = %{
      "id" => "t#{day}:#{s.index}",
      "goal" => s.task["goal"],
      "why" => s.task["why"],
      "steps" => s.steps,
      "log" => s.log,
      "waiting" => s.waiting
    }

    others = for o <- s.others, do: Map.take(o, ["goal", "why", "steps"])
    system = TaskPrompt.system_prompt(request["character"], vocabulary)
    user = TaskPrompt.user_message(materials(s1r8_request(request["material"])), task, names, others)

    record = %{
      "id" => id,
      "case" => s.case,
      "source" => s.source,
      "material" => request["material"],
      "task" => task,
      "others" => others,
      "names" => request["names"],
      "vocabulary" => request["vocabulary"],
      "system" => system,
      "user" => user
    }

    File.write!(Path.join(dir, "#{id}.json"), Jason.encode!(record, pretty: true))
    IO.puts("#{id} #{s.case} from=#{s.source}##{s.index} head=#{head_label(s.steps)} user_chars=#{String.length(user)}")
  end

  defp head_label([head | _]), do: step_label(head)
  defp head_label([]), do: "-"

  defp judge_advance(out) do
    sent = read_json(Path.join(out, "sent-advance.json"))

    rows =
      for call <- sent["calls"] do
        request = read_json(Path.join([out, "requests", "advance", "#{call["request"]}.json"]))
        vocabulary = check_vocabulary(request["vocabulary"])

        row =
          judge_call(out, "advance", call, fn text -> Tasks.check(text, vocabulary, :advance) end, &advance_reading(&1, &2, vocabulary, request))

        Map.merge(row, %{"case" => request["case"], "source" => request["source"]})
      end

    write_json(Path.join(out, "results-advance.json"), %{
      "judge" => "task_k0.exs judge-advance（产品 Tasks.check/3 :advance）",
      "rows" => rows
    })

    for row <- rows, do: IO.puts("#{row["id"]} #{row["case"]} #{row["product_result"]} #{inspect(row["reading"])}")

    review = read_json(Path.join(out, "results-review.json"))["rows"]
    summary = summarize(review, rows)
    write_json(Path.join(out, "results.json"), %{"summary" => summary, "review" => review, "advance" => rows})
    IO.puts(Jason.encode!(summary, pretty: true))
  end

  # 推进的读数：条目级（每一步单独包成 continue 交 `Tasks.check/3`）；F 情形里新的当头步是否就是失败的那一步。
  defp advance_reading(text, checked, vocabulary, request) do
    decoded = decoded(text)

    steps =
      case decoded do
        %{"steps" => steps} when is_list(steps) ->
          for step <- steps do
            one = Jason.encode!(%{"task" => "continue", "steps" => [step], "cannot" => nil, "note" => "x"})

            %{
              "raw" => step,
              "result" =>
                case Tasks.check(one, vocabulary, :advance) do
                  {:ok, _} -> "ok"
                  {:error, reason} -> inspect(reason)
                end
            }
          end

        _ ->
          nil
      end

    failed = List.first(request["task"]["log"])

    %{
      "task" => decoded && decoded["task"],
      "steps" => steps,
      "cannot" => decoded && decoded["cannot"],
      "note" => decoded && decoded["note"],
      "new_head" => checked && head_label(checked.steps),
      "repeats_failed_step" =>
        request["case"] == "F" && checked != nil && checked.steps != [] &&
          {hd(checked.steps)["kind"], hd(checked.steps)["object"]} == {failed["kind"], failed["object"]}
    }
  end

  # ---------------------------------------------------------------- 判定（plan.md 的规则）

  # 回顾一段的判定（Q1、Q2）与复测 1 起另记的读数（`review_extra`，只记录）。
  defp review_summary(review) do
    ok? = &(&1["product_result"] == ":ok")
    content_ok? = &(&1["content_result"] == ":ok")
    review_answered = Enum.filter(review, &(&1["finish_reason"] == "stop"))
    reading = &(&1["reading"] || %{})

    absent = Enum.filter(review_answered, &(&1["material"] != "R1" and content_ok?.(&1)))
    q2_n = Enum.count(absent, &(reading.(&1)["corvin_tasks"] > 0))
    named = for row <- review_answered, n <- reading.(row)["named"] || [], do: Map.put(n, "id", row["id"])

    %{
      "Q1" => %{
        "rule" => "回顾整份合法 >= 15/18",
        "ok" => Enum.count(review, ok?),
        "content_ok" => Enum.count(review, content_ok?),
        "answered" => length(review_answered),
        "holds" => Enum.count(review, ok?) >= 15,
        "failures" => for(row <- review, not ok?.(row), do: %{"id" => row["id"], "result" => row["product_result"]})
      },
      "Q2" => %{
        "rule" => "R2-R7 合法应答里开了点名 Corvin 的任务的份数 >= 7",
        "n" => q2_n,
        "of" => length(absent),
        "holds" => q2_n >= 7,
        "cannot_yet_corvin" => Enum.sum(for row <- review_answered, do: reading.(row)["cannot_yet_corvin"] || 0),
        "r1_corvin_tasks" => Enum.sum(for row <- review_answered, row["material"] == "R1", do: reading.(row)["corvin_tasks"] || 0)
      },
      "review_extra" => %{
        "cannot_yet_total" => Enum.sum(for row <- review_answered, do: reading.(row)["cannot_yet_total"] || 0),
        # 合法应答里，同一份既开了点名 Corvin 的任务、又在 cannot_yet 里写了 Corvin（K-0 同口径为 4 份）。
        "corvin_task_and_cannot_yet" =>
          for(
            row <- review_answered,
            ok?.(row),
            reading.(row)["corvin_tasks"] > 0 and reading.(row)["cannot_yet_corvin"] > 0,
            do: row["id"]
          ),
        "named_by_class" => Enum.frequencies(for n <- named, do: n["class"]),
        "static_kind" => for(n <- named, n["class"] == "static_kind", do: n),
        "outside_list" => for(n <- named, n["class"] == "outside_list", do: n),
        "unknown_kind" => for(n <- named, n["class"] == "unknown_kind", do: n),
        "kind_uses" =>
          Enum.reduce(review_answered, %{}, fn row, acc ->
            uses = reading.(row)["kind_uses"] || %{}

            Enum.reduce(Map.merge(uses["intents"] || %{}, uses["steps"] || %{}, fn _k, a, b -> a + b end), acc, fn {k, v}, acc ->
              Map.update(acc, k, v, &(&1 + v))
            end)
          end)
      }
    }
  end

  defp summarize(review, advance) do
    answered = fn rows -> Enum.filter(rows, &(&1["finish_reason"] == "stop")) end
    ok? = &(&1["product_result"] == ":ok")
    content_ok? = &(&1["content_result"] == ":ok")
    advance_answered = answered.(advance)

    named_steps =
      for row <- advance_answered, step <- (row["reading"] || %{})["steps"] || [], is_map(step["raw"]), step["raw"]["object"] != nil, do: step

    unknown_object = Enum.count(named_steps, &String.starts_with?(&1["result"], "{:unknown_object"))

    unknown_activity =
      Enum.count(
        for(row <- advance_answered, step <- (row["reading"] || %{})["steps"] || [], do: step),
        &String.starts_with?(&1["result"], "{:unknown_activity")
      )

    all = review ++ advance
    completions = for row <- all, row["usage"], do: row["usage"]["completion_tokens"]
    over = Enum.count(completions, &(&1 > 4096))
    prompts = fn rows -> for row <- rows, row["usage"], do: row["usage"]["prompt_tokens"] end
    advance_n = length(advance_answered)
    advance_ok = Enum.count(advance_answered, ok?)

    review_summary(review)
    |> Map.merge(%{
      "Q3" => %{
        "rule" => "推进合法 >= floor(0.8 * 应答)",
        "ok" => advance_ok,
        "content_ok" => Enum.count(advance, content_ok?),
        "answered" => advance_n,
        "holds" => advance_n > 0 and advance_ok >= div(8 * advance_n, 10),
        "failures" => for(row <- advance, not ok?.(row), do: %{"id" => row["id"], "result" => row["product_result"]})
      },
      "Q4" => %{
        "rule" => "带非 null object 的步骤 unknown_object == 0",
        "named_steps" => length(named_steps),
        "unknown_object" => unknown_object,
        "unknown_activity" => unknown_activity,
        "holds" => unknown_object == 0
      },
      "Q5" => %{
        "rule" => "completion_tokens > 4096 的份数 <= 2",
        "over_4096" => over,
        "of" => length(completions),
        "max" => Enum.max(completions, fn -> nil end),
        "median" => median(completions),
        "holds" => over <= 2
      },
      "Q6" => %{
        "rule" => "所有 prompt_tokens <= 6000",
        "review" => stats(prompts.(review)),
        "advance" => stats(prompts.(advance)),
        "holds" => Enum.all?(prompts.(all), &(&1 <= 6000))
      },
      "advance_tasks" => Enum.frequencies(for row <- advance_answered, do: (row["reading"] || %{})["task"]),
      "advance_by_case" =>
        for(
          {c, rows} <- Enum.group_by(advance, & &1["case"]),
          into: %{},
          do: {c, %{"n" => length(rows), "ok" => Enum.count(rows, ok?), "tasks" => Enum.frequencies(for r <- rows, do: r["reading"] && r["reading"]["task"])}}
        ),
      "f_repeats_failed_step" => Enum.count(advance, &(&1["reading"] && &1["reading"]["repeats_failed_step"] == true)),
      "usage" => %{
        "prompt" => Enum.sum(prompts.(all)),
        "prompt_cache_hit" => Enum.sum(for row <- all, row["usage"], do: row["usage"]["prompt_cache_hit_tokens"] || 0),
        "completion" => Enum.sum(completions),
        "reasoning" =>
          Enum.sum(for row <- all, row["usage"], do: get_in(row["usage"], ["completion_tokens_details", "reasoning_tokens"]) || 0)
      }
    })
  end

  defp median([]), do: nil

  defp median(list) do
    sorted = Enum.sort(list)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp stats([]), do: nil
  defp stats(list), do: %{"min" => Enum.min(list), "median" => median(list), "max" => Enum.max(list)}

  # ---------------------------------------------------------------- 共用

  defp judge_call(out, phase, call, check, reading) do
    base = Map.take(call, ["id", "request", "status", "elapsed_ms", "usage", "error"])

    case call["status"] do
      200 ->
        response = read_json(Path.join([out, "raw", phase, "#{call["id"]}.json"]))
        written = read_chat(response)
        product = if call["elapsed_ms"] > @product_timeout_ms, do: {:error, :timeout}, else: written
        text = with {:ok, %{text: text}} <- written, do: text, else: (_ -> nil)
        content = if text, do: check.(text), else: written
        product_result = if match?({:ok, _}, product), do: check.(text), else: product
        checked = with {:ok, checked} <- content, do: checked, else: (_ -> nil)

        Map.merge(base, %{
          "material" => material_of(out, phase, call),
          "finish_reason" => get_in(response, ["choices", Access.at(0), "finish_reason"]),
          "text" => text,
          "reasoning_chars" =>
            String.length(get_in(response, ["choices", Access.at(0), "message", "reasoning_content"]) || ""),
          "product_result" => label(product_result),
          "content_result" => label(content),
          "checked" => checked && json_safe(checked),
          "reading" => text && reading.(text, checked)
        })

      _ ->
        Map.merge(base, %{"product_result" => "not_answered", "content_result" => "not_answered"})
    end
  end

  defp material_of(out, phase, call),
    do: read_json(Path.join([out, "requests", phase, "#{call["request"]}.json"]))["material"]

  defp label({:ok, _}), do: ":ok"
  defp label({:error, reason}), do: inspect(reason)

  # 同 `Writer.read_chat/2`（私有）：`finish_reason` 为 "stop" 且 content 是非空字符串才算写成。
  defp read_chat(%{"choices" => [%{"finish_reason" => "stop"} = choice | _]} = response) do
    case get_in(choice, ["message", "content"]) do
      text when is_binary(text) and text != "" -> {:ok, %{text: text, usage: response["usage"]}}
      _ -> {:error, :no_text}
    end
  end

  defp read_chat(%{"choices" => [choice | _]}) when is_map(choice),
    do: {:error, {:finish_reason, choice["finish_reason"]}}

  defp read_chat(_), do: {:error, :invalid_response}

  # 读数用的解码：同 `DayPlan.decode/1`（产品的去围栏与解码）；不是对象为 nil。
  defp decoded(text) do
    case NpcServer.Life.DayPlan.decode(text) do
      {:ok, answer} -> answer
      {:error, _} -> nil
    end
  end

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_), do: []

  defp tasks_open(%{"tasks" => %{"open" => open}}) when is_list(open), do: open
  defp tasks_open(_answer), do: []

  defp corvin_task?(task), do: Enum.any?(task["steps"], &(&1["object"] == %{"actor" => @corvin}))

  defp step_label(%{"kind" => kind, "object" => nil}), do: kind
  defp step_label(%{"kind" => kind, "object" => %{"actor" => cid}}), do: "#{kind} actor #{cid}"

  defp count_corvin(nil), do: 0

  defp count_corvin(wants),
    do: Enum.count(wants, &(Jason.encode!(&1) =~ ~r/Corvin|#{@corvin}/))

  # 应答里各种类被写了几次（意图、任务步合计；读原文，不经检查）。
  defp kind_uses(nil), do: %{}

  defp kind_uses(answer) do
    intents = for i <- list_or_empty(answer["intents"]), is_map(i), do: i["activity"]

    steps =
      for t <- tasks_open(answer),
          is_map(t),
          s <- list_or_empty(t["steps"]),
          is_map(s),
          do: s["activity"]

    %{"intents" => Enum.frequencies(intents), "steps" => Enum.frequencies(steps)}
  end

  # 检查结果里有原子键与原子值：转成能过 JSON 的形状。
  defp json_safe(term), do: term |> to_json() |> Jason.encode!() |> Jason.decode!()

  defp to_json(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), to_json(v)} end)
  defp to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)
  defp to_json(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp to_json(other), do: other

  defp sent?(call), do: not String.starts_with?(call["error"] || "", "not_sent")

  # Life 起规划槽时交进快照的词表：`Offers.plan_kinds/1` 的种类（T-2 前任务词表就是它），对象是人的种类展开成
  # `%{显示名 => %{"actor" => cid}}`。
  defp vocabulary(name) do
    others = Map.get(@others, name, [])
    names = Map.new(others, &{&1.entity_id, &1.name})
    people = Enum.uniq(@relationships ++ Enum.map(others, & &1.entity_id))

    for %{kind: kind, criterion: criterion, objects: objects} <-
          Offers.plan_kinds(%{activities: activities(), skills: %{speak: %{}}}) do
      objects =
        case objects do
          :none -> %{}
          :people -> Map.new(people, &{State.person(&1, names), %{"actor" => &1}})
        end

      %{kind: kind, criterion: criterion, objects: objects}
    end
  end

  defp names(name), do: Map.new(Map.get(@others, name, []), &{Integer.to_string(&1.entity_id), &1.name})

  defp encode_vocabulary(vocabulary),
    do: for(%{kind: k, criterion: c, objects: o} <- vocabulary, do: %{"kind" => k, "criterion" => c, "objects" => o})

  defp runtime_vocabulary(list),
    do: for(%{"kind" => k, "criterion" => c, "objects" => o} <- list, do: %{kind: k, criterion: c, objects: o})

  defp check_vocabulary(list), do: Map.new(list, &{&1["kind"], &1["objects"]})

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()
  defp write_json(path, term), do: File.write!(path, Jason.encode!(term, pretty: true))

  # ---------------------------------------------------------------- 输入（同 s1r8b_0b.exs）

  defp s1r8_request(name) do
    [first | rest] =
      for k <- 1..3, do: Path.join([@s1r8, "requests", "#{name}-r#{k}.json"]) |> File.read!()

    true = Enum.all?(rest, &(&1 == first)) || raise "#{name}: 三次请求体不同"
    Jason.decode!(first)
  end

  defp activities do
    for %{"name" => name, "criterion" => criterion} <-
          Path.join([@fixtures, "day_plan", "activities.json"]) |> File.read!() |> Jason.decode!(),
        do: %{name: name, criterion: criterion}
  end

  defp character(request) do
    [first | _] = String.split(request["system"], "\n")
    "You are this person: " <> character = first
    character
  end

  defp user_of(request), do: request["messages"] |> hd() |> Map.fetch!("content")

  defp materials(request) do
    [right_now, happened, thoughts, "Plan the rest of today now."] =
      request |> user_of() |> String.split("\n\n")

    "Right now:\n" <> right_now_lines = right_now
    "What happened:\n" <> happened_lines = happened

    "What I thought before (my own earlier thoughts, not facts):\nAbout this: " <> after_this =
      thoughts

    [this, others] = String.split(after_this, "\nAbout other things: ", parts: 2)

    %{
      right_now: String.split(right_now_lines, "\n"),
      happened:
        happened_lines |> String.split("\n") |> Enum.map(&Regex.replace(~r/^\[\d+\] /, &1, "")),
      thought_before: if(this == "nothing yet", do: nil, else: this),
      other_thoughts: if(others == "nothing yet", do: [], else: String.split(others, "\n"))
    }
  end

  defp clock(line) do
    [_, hh, mm, day] = Regex.run(~r/^It is [a-z ]+, (\d\d):(\d\d)\. It is day (\d+)\.$/, line)
    {"#{hh}:#{mm}", String.to_integer(hh) * 60 + String.to_integer(mm), String.to_integer(day)}
  end
end

TaskK0.main(System.argv())
