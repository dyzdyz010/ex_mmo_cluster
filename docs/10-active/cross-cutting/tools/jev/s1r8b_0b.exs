# S1-R8b（稿 A 批 0b 的离线重放）：用**当前产品代码**渲染规划请求、用产品的 `DayPlan.check/3` 判应答。
#
# 是什么
#   规格是 `.demo/observe/npc-slice1-20261112/s1r8b-0b/plan.md`（发问前写定）。本脚本只做两件 Elixir 侧的事，
#   发请求由同目录的 `s1r8b_0b_replay.py` 做（key 只进那个 Python 进程）：
#     render  每份材料渲染一次规划提示词，写 `<out>/requests/<材料>.json`（system、user、此刻、词表）；
#     judge   读 Python 存下的 `<out>/raw/` 与 `<out>/sent.json`，逐份经 `Round.write/1` → `DayPlan.check/3` 判，
#             另把每条意图 / cannot_yet 单独交给 `DayPlan.check/3` 得条目级结论，写 `<out>/results.json`。
#
# 为什么这样取
#   - 系统提示词：经 `DayPlan.Round.write/1` 渲染（说话一类的可选对象句在 Round 的私有 `listed/1` 里，只能从这里拿到），
#     写作函数换成“把 system / user 交回本进程”的替身。Round 需要先走“此刻一块”与召回才会调写作函数，所以快照里给
#     真实夹具观察（`test/support/fixtures/reflection/round4-rawobs.txt`）、空召回替身与一条占位经历——这三样只为走到
#     写作函数，Round 拼出的用户消息**丢弃不用**。
#   - 用户消息：S1-R8 的真实材料（`s1r8/requests/<材料>-r1.json`）按 `npc_life_day_plan_prompt_test.exs` 的拆法拆回
#     `materials`，再交给产品的 `Prompt.user_message/1`（Round 用的同一个函数）；断言与 S1-R8 发出的字节相同。
#   - 词表：`Offers.plan_kinds/1`（profile = S1-R7 的六个候选 + speak 技能；Registry 给每个 npc profile 都配 speak），
#     对象按 Life 起规划槽的展开（`Life.vocabulary/2` 是私有函数，这里用同样的公开函数 `State.person/2` 组合，次序同它：
#     关系里的人在前、观察里的他人在后、去重）。人与名字的来源见下面 `@people` 的注释。
#   - 对照：同一材料、只有静态种类的词表（profile 不配 speak）经同一条 Round 路径渲染，断言与 S1-R8 的 system 逐字节相同；
#     有说话一类时，去掉说话那一行后也必须与 S1-R8 相同（只多出一行）。
#
# 怎么运行（WSL；经 `.demo/observe/npc-slice1-20261112/s1r8b-0b/mix.sh`，在 apps/npc_server 下）
#   mix run --no-start <本文件> render <out>
#   mix run --no-start <本文件> judge <out>
# 不连库、不起节点、不发网络请求。

defmodule S1R8b.NoRecall do
  @moduledoc "只离线：召回替身，两路都返回空。只为让 Round 走到写作函数；Round 拼出的用户消息不用（见文件头）。"
  def recall(_config, _description, _now_ms), do: {:ok, %{results: [], latency_ms: 0}}
end

defmodule S1R8b do
  alias NpcServer.Life.DayPlan
  alias NpcServer.Life.DayPlan.{Prompt, Round}
  alias NpcServer.Life.State
  alias NpcServer.Offers

  @root Path.expand("../../../../..", __DIR__)
  @s1r8 Path.join(@root, ".demo/observe/npc-slice1-20261112/s1r8")
  @fixtures Path.join(@root, "apps/npc_server/test/support/fixtures")

  # S1-R8 的六份材料（S1-R7 第 1、2、3、4、5、7 轮“自己”一问）。
  @materials ["R1", "R2", "R3", "R4", "R5", "R7"]

  # Garen（S1-R7 cid 1689289494529）与 Corvin。来源（plan.md “材料”一节）：
  #   关系表：`s1r7/export/rows/*-round{1..7}-row.json` 的 `state.relationships`，六轮都恰好只有 Corvin；
  #   观察里的他人：材料“此刻”一块（产品 `Mind.situation/2` 由 `State.others/1` 写成）——R1 为
  #   `Nearby: Corvin (NPC, actor 1906495721474, 8.9 m away)`，其余五份为 `Nobody else is nearby.`（即 others 为空）。
  #   Tobin（9085650997251）只出现在 R5 / R7 的记忆里，不在关系表、不在观察里，所以产品不会把他列为可点名的人。
  @garen 1_689_289_494_529
  @corvin 1_906_495_721_474
  @others %{"R1" => [%{entity_id: @corvin, name: "Corvin"}]}
  @relationships [@corvin]

  def main(["render", out]), do: render(out)
  def main(["judge", out]), do: judge(out)

  # ---------------------------------------------------------------- render

  defp render(out) do
    File.mkdir_p!(Path.join(out, "requests"))
    activities = activities()

    for name <- @materials do
      request = s1r8_request(name)
      character = character(request)
      materials = materials(request)
      {now, now_minute, day} = clock(hd(materials.right_now))
      speak_vocabulary = vocabulary(%{activities: activities, skills: %{speak: %{}}}, name)
      static_vocabulary = vocabulary(%{activities: activities}, name)

      system = capture_system(character, speak_vocabulary, now_minute, day)
      control = capture_system(character, static_vocabulary, now_minute, day)
      user = Prompt.user_message(materials)

      # 对照断言：只有静态种类时与 S1-R8 逐字节相同；有说话一类时恰好多出说话那一行。
      true = control == request["system"] || raise "#{name}: 静态词表的 system 与 S1-R8 不同"
      true = user == user_of(request) || raise "#{name}: 用户消息与 S1-R8 不同"
      [speak_line] = String.split(system, "\n") -- String.split(control, "\n")
      true = String.replace(system, "\n" <> speak_line, "") == control || raise "#{name}: 不止多一行"

      record = %{
        "material" => name,
        "now" => now,
        "now_minute" => now_minute,
        "day" => day,
        "system" => system,
        "user" => user,
        "speak_line" => speak_line,
        "vocabulary" =>
          for(
            %{kind: kind, criterion: criterion, objects: objects} <- speak_vocabulary,
            do: %{"kind" => kind, "criterion" => criterion, "objects" => objects}
          ),
        "checks" => %{
          "static_system_equals_s1r8" => true,
          "user_equals_s1r8" => true,
          "system_minus_speak_line_equals_s1r8" => true
        }
      }

      File.write!(Path.join([out, "requests", "#{name}.json"]), Jason.encode!(record, pretty: true))
      IO.puts("render #{name} now=#{now} objects=#{inspect(Map.keys(List.last(speak_vocabulary).objects))}")
      IO.puts("  #{speak_line}")
    end

    :ok
  end

  # Life 起规划槽时交进快照的词表：`Offers.plan_kinds/1` 的种类，对象是人的种类展开成 `%{显示名 => %{"actor" => cid}}`。
  defp vocabulary(profile, name) do
    others = Map.get(@others, name, [])
    names = Map.new(others, &{&1.entity_id, &1.name})
    people = Enum.uniq(@relationships ++ Enum.map(others, & &1.entity_id))

    for %{kind: kind, criterion: criterion, objects: objects} <- Offers.plan_kinds(profile) do
      objects =
        case objects do
          :none -> %{}
          :people -> Map.new(people, &{State.person(&1, names), %{"actor" => &1}})
        end

      %{kind: kind, criterion: criterion, objects: objects}
    end
  end

  # 经 Round.write/1 拿到它交给写作函数的 system（写作函数是替身，返回一个失败，Round 就此结束）。
  defp capture_system(character, vocabulary, now_minute, day) do
    parent = self()

    snapshot =
      base_snapshot(character, vocabulary, now_minute, day, fn system, user ->
        send(parent, {:captured, system, user})
        {:error, :offline_capture}
      end)

    %{result: {:failed, :offline_capture}, wrote: true} = Round.write(snapshot)
    assert_one_capture()
  end

  defp assert_one_capture do
    receive do
      {:captured, system, _user_discarded} ->
        receive do
          {:captured, _, _} -> raise "写作函数被调了不止一次"
        after
          0 -> system
        end
    after
      0 -> raise "Round 没有调写作函数"
    end
  end

  defp base_snapshot(character, vocabulary, now_minute, day, write) do
    %{
      cid: @garen,
      kind: :day,
      day: day,
      now_minute: now_minute,
      now_ms: 0,
      observation: rawobs(),
      recent: [%{at_ms: 0, text: "offline placeholder (only to reach the write function)"}],
      buildings: [],
      people: [],
      names: %{},
      latest: %{},
      adapter: S1R8b.NoRecall,
      config: %{},
      context: %{cid: @garen},
      character: character,
      vocabulary: vocabulary,
      today: [],
      wants: [],
      write: write
    }
  end

  # ---------------------------------------------------------------- judge

  # 产品写作超时：`NpcServer.Http` 的缺省 `timeout_ms` 60 s（写作 endpoint 不设 timeout_ms，Life 只加后台车道）。
  @product_timeout_ms 60_000

  defp judge(out) do
    sent = Path.join(out, "sent.json") |> File.read!() |> Jason.decode!()

    rows =
      for call <- sent["calls"] do
        request =
          Path.join([out, "requests", "#{call["material"]}.json"]) |> File.read!() |> Jason.decode!()

        judge_call(out, call, request)
      end

    File.write!(
      Path.join(out, "results.json"),
      Jason.encode!(%{"judge" => "s1r8b_0b.exs judge（产品 Round.write/1 → DayPlan.check/3）", "rows" => rows},
        pretty: true
      )
    )

    for row <- rows,
        do: IO.puts("#{row["id"]} #{row["product_result"]} items=#{inspect(row["item_summary"])}")

    :ok
  end

  defp judge_call(out, call, request) do
    base = Map.take(call, ["id", "material", "attempt", "status", "elapsed_ms", "usage", "error"])

    case call["status"] do
      200 ->
        response = Path.join([out, "raw", "#{call["id"]}.json"]) |> File.read!() |> Jason.decode!()
        written = read_chat(response)
        vocabulary = runtime_vocabulary(request["vocabulary"])
        now_minute = request["now_minute"]

        # 产品的结局：经 Round.write/1（它调 DayPlan.check/3）。超过产品 60 s 的，产品里是写作超时。
        product_written =
          if call["elapsed_ms"] > @product_timeout_ms, do: {:error, :timeout}, else: written

        result = round_result(request, vocabulary, now_minute, product_written)
        content = round_result(request, vocabulary, now_minute, written)
        text = with {:ok, %{text: text}} <- written, do: text, else: (_ -> nil)
        items = if text, do: items(text, vocabulary, now_minute), else: nil

        Map.merge(base, %{
          "finish_reason" => get_in(response, ["choices", Access.at(0), "finish_reason"]),
          "text" => text,
          "reasoning_chars" =>
            String.length(get_in(response, ["choices", Access.at(0), "message", "reasoning_content"]) || ""),
          "product_result" => inspect(result.result),
          "content_result" => inspect(content.result),
          "checked" => content.checked && encode_checked(content.checked),
          "items" => items,
          "item_summary" => items && summary(items)
        })

      _ ->
        Map.merge(base, %{"product_result" => "not_answered", "content_result" => "not_answered"})
    end
  end

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

  defp round_result(request, vocabulary, now_minute, written) do
    snapshot =
      base_snapshot(character(request), vocabulary, now_minute, request["day"], fn _system, _user ->
        written
      end)

    Round.write(snapshot)
  end

  # requests/<材料>.json 里的词表还原成快照形状（对象表的值是 `%{"actor" => cid}`，JSON 往返不变）。
  defp runtime_vocabulary(list) do
    for %{"kind" => kind, "criterion" => criterion, "objects" => objects} <- list,
        do: %{kind: kind, criterion: criterion, objects: objects}
  end

  # 条目级：整份是 JSON 对象时，把每条意图 / cannot_yet 各自单独包成一份计划交给 `DayPlan.check/3`。
  # 去围栏同 `DayPlan.check/3` 的写法（至多一对 ```，可带 json）；整份不是 JSON 对象就没有条目级结论。
  defp items(text, vocabulary, now_minute) do
    body =
      case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, String.trim(text)) do
        [_, inner] -> inner
        nil -> String.trim(text)
      end

    case Jason.decode(body) do
      {:ok, %{} = plan} ->
        intents =
          for intent <- List.wrap(plan["intents"]) do
            one = Jason.encode!(%{"intents" => [intent], "cannot_yet" => []})

            %{
              "raw" => intent,
              "result" => check_label(DayPlan.check(one, check_vocabulary(vocabulary), now_minute))
            }
          end

        wants =
          for want <- List.wrap(plan["cannot_yet"]) do
            one = Jason.encode!(%{"intents" => [], "cannot_yet" => [want]})

            %{
              "raw" => want,
              "result" => check_label(DayPlan.check(one, check_vocabulary(vocabulary), now_minute))
            }
          end

        %{"intents" => intents, "cannot_yet" => wants}

      _ ->
        nil
    end
  end

  # Round 交给 `DayPlan.check/3` 的同一种词表形状 `%{种类 => %{显示名 => 对象}}`。
  defp check_vocabulary(vocabulary), do: Map.new(vocabulary, &{&1.kind, &1.objects})

  defp check_label({:ok, _}), do: "ok"
  defp check_label({:error, reason}), do: inspect(reason)

  defp summary(%{"intents" => intents, "cannot_yet" => wants}) do
    %{
      "intents" => length(intents),
      "intents_ok" => Enum.count(intents, &(&1["result"] == "ok")),
      "cannot_yet" => length(wants),
      "cannot_yet_ok" => Enum.count(wants, &(&1["result"] == "ok"))
    }
  end

  defp encode_checked(%{intents: intents, wants: wants}),
    do: %{"intents" => intents, "wants" => wants}

  # ---------------------------------------------------------------- 输入

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

  defp rawobs do
    text = File.read!(Path.join([@fixtures, "reflection", "round4-rawobs.txt"]))
    {%{observation: observation}, _} = Code.eval_string(text)
    observation
  end

  defp character(request) do
    [first | _] = String.split(request["system"], "\n")
    "You are this person: " <> character = first
    character
  end

  defp user_of(request), do: request["messages"] |> hd() |> Map.fetch!("content")

  # 同 `npc_life_day_plan_prompt_test.exs` 的 `materials/1`：按 `\n\n` 切三块材料与末行，各块去掉标题、编号与前缀。
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

  # 此刻一块第一行 `It is <时段>, HH:MM. It is day N.`：给出 HH:MM、日内分钟（`check/3` 的 `by` 要严格晚于它）与日号。
  defp clock(line) do
    [_, hh, mm, day] = Regex.run(~r/^It is [a-z ]+, (\d\d):(\d\d)\. It is day (\d+)\.$/, line)
    {"#{hh}:#{mm}", String.to_integer(hh) * 60 + String.to_integer(mm), String.to_integer(day)}
  end
end

S1R8b.main(System.argv())
