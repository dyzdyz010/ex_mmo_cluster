# 失败原因直白英文的离线对照（探索，不是验收）：用**产品代码**渲染任务推进请求的旧 / 新两版，用产品 `Tasks.check/3` 判应答。
#
# 是什么
#   规格是 `.demo/observe/npc-reason-wording-20261119/plan.md`（发问前写定）。只做 Elixir 侧的事，发请求复用
#   `reason_wording_replay.py`（包一层 `task_k0_replay.py`，key 只进那个 Python 进程）：
#     render <out> old|new  把 K-0 复测里带 `gather: exhausted` 的三个 F 用例经产品 `Tasks.Prompt` 渲染成
#                           `<out>/requests/advance/<old|new>-<用例>.json`。旧版要在改 `Mind.result/1` 之前跑，并断言与复测存下的
#                           system / user 逐字节相同；新版断言 system 与旧版相同、用户消息只差结局那一行。
#     manifest <out>        按 plan.md 的发送次序写 `<out>/requests/advance/manifest.json`（12 次）。
#     judge <out>           读 `<out>/raw/advance/` 与 `sent-advance.json`，逐份经产品 `Tasks.check/3`（:advance）判、按 plan.md 的规则读，
#                           写 `<out>/results.json`。
#
# 输入：任务、其它任务、名字、词表、材料名取自 `.demo/observe/npc-task-k0-20261119/retest-1/requests/advance/A0{1,2,4}.json`
#   （K-0 复测按产品渲染时存下的记录）；材料按 `task_k0.exs` 的同一拆法从 S1-R8 导出取回（下面几个私有函数照抄自 task_k0.exs，
#   那个脚本加载即执行自己的 main，不能 require）。
#
# 怎么运行（WSL；经 `.demo/observe/npc-reason-wording-20261119/mix.sh`，在 apps/npc_server 下）
#   mix run --no-start <本文件> render <out> old   ……   mix run --no-start <本文件> judge <out>
# 不连库、不起节点、不发网络请求。

defmodule ReasonWording do
  alias NpcServer.Life.Tasks
  alias NpcServer.Life.Tasks.Prompt, as: TaskPrompt

  @root Path.expand("../../../../..", __DIR__)
  @s1r8 Path.join(@root, ".demo/observe/npc-slice1-20261112/s1r8")
  @retest Path.join(@root, ".demo/observe/npc-task-k0-20261119/retest-1/requests/advance")
  @cases ["A01", "A02", "A04"]
  @rounds 2
  @cap 12
  @product_timeout_ms 60_000

  # plan.md “判定”的正则（只读应答正文的 note 与 cannot）。
  @fatigue [
    ~r/\b(tired|weary|fatigue|fatigued|rest|resting|strength|sleep|worn out|recover)\b/,
    ~r/\bi(?: was|'m| am| felt)? (?:so |too |completely )?exhausted\b/,
    ~r/exhausted myself/
  ]
  @right [
    ~r/(pile|heap|quarry|there|spot|source|stone)[^.]{0,60}(empty|exhausted|nothing left|ran out|run out|used up|no more|bare|spent|depleted|cut out|picked clean)/,
    ~r/(nothing|no stone|none) (left|remaining)/,
    ~r/ran out/,
    ~r/run out/
  ]

  def main(["render", out, variant]) when variant in ["old", "new"], do: render(out, variant)
  def main(["manifest", out]), do: manifest(out)
  def main(["judge", out]), do: judge(out)

  defp render(out, variant) do
    dir = Path.join([out, "requests", "advance"])
    File.mkdir_p!(dir)

    for id <- @cases do
      source = read_json(Path.join(@retest, "#{id}.json"))
      names = for {cid, name} <- source["names"], into: %{}, do: {String.to_integer(cid), name}
      vocabulary = runtime_vocabulary(source["vocabulary"])
      system = TaskPrompt.system_prompt(character(s1r8_request(source["material"])), vocabulary)

      user =
        TaskPrompt.user_message(
          materials(s1r8_request(source["material"])),
          source["task"],
          names,
          source["others"]
        )

      case variant do
        "old" ->
          true = system == source["system"] || raise "#{id}: 旧版 system 与复测记录不同"
          true = user == source["user"] || raise "#{id}: 旧版 user 与复测记录不同"

        "new" ->
          old = read_json(Path.join(dir, "old-#{id}.json"))
          true = system == old["system"] || raise "#{id}: 新版 system 与旧版不同"

          changed =
            List.myers_difference(String.split(old["user"], "\n"), String.split(user, "\n"))

          removed = for {:del, lines} <- changed, line <- lines, do: line
          added = for {:ins, lines} <- changed, line <- lines, do: line

          true =
            removed == ["- gather_stone: failed (gather: exhausted)"] ||
              raise "#{id}: 旧行 #{inspect(removed)}"

          [new_line] = added
          IO.puts("#{id} new line: #{new_line}")
      end

      record =
        Map.merge(
          Map.take(source, ["case", "source", "material", "task", "others", "names", "vocabulary"]),
          %{
            "id" => "#{variant}-#{id}",
            "variant" => variant,
            "from" => "retest-1/requests/advance/#{id}.json",
            "system" => system,
            "user" => user
          }
        )

      File.write!(Path.join(dir, "#{variant}-#{id}.json"), Jason.encode!(record, pretty: true))
      IO.puts("#{variant}-#{id} rendered user_chars=#{String.length(user)}")
    end
  end

  defp manifest(out) do
    calls =
      for round <- 1..@rounds, id <- @cases, variant <- ["old", "new"] do
        %{"id" => "#{variant}-#{id}-r#{round}", "request" => "#{variant}-#{id}"}
      end

    true = length(calls) <= @cap || raise "超过上限 #{@cap}"

    File.write!(
      Path.join([out, "requests", "advance", "manifest.json"]),
      Jason.encode!(%{"calls" => calls}, pretty: true)
    )

    IO.puts("manifest calls=#{length(calls)}")
  end

  defp judge(out) do
    sent = read_json(Path.join(out, "sent-advance.json"))

    rows =
      for call <- sent["calls"] do
        request = read_json(Path.join([out, "requests", "advance", "#{call["request"]}.json"]))
        vocabulary = Map.new(request["vocabulary"], &{&1["kind"], &1["objects"]})

        base =
          Map.take(call, ["id", "request", "status", "elapsed_ms", "usage", "error"])
          |> Map.put("variant", request["variant"])

        case call["status"] do
          200 ->
            response = read_json(Path.join([out, "raw", "advance", "#{call["id"]}.json"]))
            choice = hd(response["choices"])
            reasoning = get_in(choice, ["message", "reasoning_content"]) || ""
            written = read_chat(response)

            product =
              if call["elapsed_ms"] > @product_timeout_ms, do: {:error, :timeout}, else: written

            {result, checked, text} =
              case product do
                {:ok, %{text: text}} ->
                  case Tasks.check(text, vocabulary, :advance) do
                    {:ok, checked} -> {":ok", checked, text}
                    {:error, reason} -> {inspect(reason), nil, text}
                  end

                {:error, reason} ->
                  {inspect(reason), nil, nil}
              end

            answer = text && decoded(text)

            fields =
              answer && String.downcase("#{answer["note"]} #{Jason.encode!(answer["cannot"])}")

            reading =
              cond do
                fields == nil -> "unwritten"
                Enum.any?(@fatigue, &Regex.match?(&1, fields)) -> "fatigue"
                Enum.any?(@right, &Regex.match?(&1, fields)) -> "right"
                true -> "unclear"
              end

            Map.merge(base, %{
              "finish_reason" => choice["finish_reason"],
              "product_result" => result,
              "reading" => reading,
              "task" => answer && answer["task"],
              "note" => answer && answer["note"],
              "cannot" => answer && answer["cannot"],
              "new_head" => checked && head(checked.steps),
              "repeats_failed_step" =>
                checked != nil and checked.steps != [] and
                  hd(checked.steps)["kind"] == "gather_stone",
              "completion_tokens" => get_in(response, ["usage", "completion_tokens"]),
              "reasoning_chars" => String.length(reasoning),
              "reasoning_fatigue_words" =>
                Enum.sum(
                  for re <- @fatigue, do: length(Regex.scan(re, String.downcase(reasoning)))
                )
            })

          _ ->
            Map.merge(base, %{"product_result" => "not_answered", "reading" => "unwritten"})
        end
      end

    summary =
      for variant <- ["old", "new"], into: %{} do
        mine = Enum.filter(rows, &(&1["variant"] == variant))
        out_tokens = for r <- mine, n = r["completion_tokens"], do: n

        {variant,
         %{
           "answers" => length(mine),
           "valid" => Enum.count(mine, &(&1["product_result"] == ":ok")),
           "readings" => Enum.frequencies(Enum.map(mine, & &1["reading"])),
           "length_cut" => Enum.count(mine, &(&1["finish_reason"] == "length")),
           "repeats_failed_step" => Enum.count(mine, &(&1["repeats_failed_step"] == true)),
           "completion_tokens" => stats(out_tokens),
           "prompt_tokens" =>
             stats(for r <- mine, n = get_in(r, ["usage", "prompt_tokens"]), do: n)
         }}
      end

    File.write!(
      Path.join(out, "results.json"),
      Jason.encode!(
        %{
          "judge" => "reason_wording.exs judge（产品 Tasks.check/3 :advance；plan.md 的读法）",
          "summary" => summary,
          "rows" => rows
        },
        pretty: true
      )
    )

    for r <- rows,
        do:
          IO.puts(
            "#{r["id"]} #{r["product_result"]} #{r["finish_reason"]} #{r["reading"]} out=#{r["completion_tokens"]} note=#{inspect(r["note"])}"
          )

    IO.puts(Jason.encode!(summary, pretty: true))
  end

  defp head([%{"kind" => kind} | _]), do: kind
  defp head([]), do: "-"

  defp stats([]), do: nil

  defp stats(list) do
    sorted = Enum.sort(list)

    %{
      "min" => hd(sorted),
      "median" => Enum.at(sorted, div(length(sorted), 2)),
      "max" => List.last(sorted)
    }
  end

  # —— 以下照抄 task_k0.exs（同一拆法） ——

  defp read_chat(%{"choices" => [%{"finish_reason" => "stop"} = choice | _]} = response) do
    case get_in(choice, ["message", "content"]) do
      text when is_binary(text) and text != "" -> {:ok, %{text: text, usage: response["usage"]}}
      _ -> {:error, :no_text}
    end
  end

  defp read_chat(%{"choices" => [choice | _]}) when is_map(choice),
    do: {:error, {:finish_reason, choice["finish_reason"]}}

  defp read_chat(_), do: {:error, :invalid_response}

  defp decoded(text) do
    case NpcServer.Life.DayPlan.decode(text) do
      {:ok, %{} = answer} -> answer
      _ -> nil
    end
  end

  defp runtime_vocabulary(list),
    do:
      for(
        %{"kind" => k, "criterion" => c, "objects" => o} <- list,
        do: %{kind: k, criterion: c, objects: o}
      )

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp s1r8_request(name) do
    [first | rest] =
      for k <- 1..3, do: Path.join([@s1r8, "requests", "#{name}-r#{k}.json"]) |> File.read!()

    true = Enum.all?(rest, &(&1 == first)) || raise "#{name}: 三次请求体不同"
    Jason.decode!(first)
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
end

ReasonWording.main(System.argv())
