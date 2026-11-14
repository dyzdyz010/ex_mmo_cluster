defmodule NpcServer.Life.Reflection.Round do
  @moduledoc """
  一轮反思的流程（内容规范 §10.11、§10.12 的 R3）：在 Life 的反思槽 worker 里串行地取材料、写日记、检查、重问，
  再把写成的几条存档到反思库。规则与提示词都在 `NpcServer.Life.Reflection`，给模型看的英文渲染都在 `NpcServer.Mind`；
  这里只把它们按离线测量 S1-X2 的做法（`.demo/observe/npc-slice1-20261112/s1x2/plan.md` 的“做法”与“运行前补记”）串起来。

  不回头问 Life：Life 起槽那一刻把需要的一切取齐成快照交进来（见 `write/1`），I/O 只经快照里的 Hindsight 适配器、
  写日记的函数与 World 路由。两个公开入口对应“落栏不等存档”：worker 先 `write/1`、把结果交回 Life 落栏，再 `archive/2`。

      write/1：定问题 → 此刻一块（一轮渲染一次）→ 每问：两次召回 → 四块材料 → 写 → 检查 →（不合格原样重问一次）
      archive/2：本轮写成的各条 → 反思库 ensure_bank + retain（一条都没写成就不存）

  Hindsight 与写日记的请求都不并行。写日记或召回失败（HTTP、超时、`stop_reason` 等），这一问记失败、这一轮到此为止，
  后面的问题不再发请求（额度或认证类错误不连着重试）；已写成的照常交回。每一步一行 `npc_reflect cid=<cid> …` 日志，
  日记正文不进日志。
  """
  require Logger
  alias NpcServer.Life
  alias NpcServer.Life.Reflection
  alias NpcServer.Mind

  # 每问两次召回（离线脚本 `s1x2_reflect.py` 的 RAW_TYPES / OBS_TYPES 与各自的 token 上限）：原始经历与带次数的认识。
  @recalls [{["experience", "world"], 1500}, {["observation"], 800}]

  @doc """
  写一轮。`snapshot` 由 Life 在起槽那一刻取齐：

      cid          永久 cid（日志用）
      round        `%{at_ms:, score:, causes:}`（`Reflection.record/2` 或 `Reflection.manual/2` 给的那一轮；
                   `at_ms` 是触发那条经历的时刻，只进日志）
      new          自上一轮开始以来的新经历 `[%{"at_ms", "tags"}]`
      now_ms       这一轮的“此刻”（Life 起槽那一刻的时钟，同离线的 t′）：多久以前、召回的时刻参数都相对它；
                   日记是这一刻想的，所以 `"latest"` 各条与存档文档的时刻也是它
      observation  此刻的观察（Body 的 Observation，带 `world_time`）
      recent       还没写进 Hindsight 的经历 `[%{at_ms:, text:}]`，旧在前（同 `Life.mind/2` 的 `recent`）
      buildings    我放下的有名字的建筑（`Life.State` 的 `"buildings"`，记得的次序）
      people       有关系的人的 cid（`Life.State.relationships/1` 的次序）
      names        `%{cid => 名字}`（此刻观察里的人名）
      latest       持久行里各问最新的一条 `%{键 => %{"at_ms", "journal", "closing", "text"}}`
      adapter      Hindsight 适配器；config 经历库的 config（单路超时已设好）
      write        写日记的函数 `fn system, user -> {:ok, %{text:, usage:}} | {:error, 原因} end`
      character    人格卡一行（`Persona.describe/2`）
      context      现查 World 用（`Life.standing/2`）

  返回交回 Life 落栏的结果：`%{at_ms: 这一轮的此刻 now_ms, score:, causes:, asked: [键], written: [%{key:, entry:}],
  discarded: [键], failed: [键], reasked: 次数, error: nil | 原因, elapsed_ms:}`。`entry` 就是进持久行 `"latest"` 的那一份；
  `written` 里另带 `question`（存档用）。

  `error` 为 nil ⇔ 这一轮**做完**了：每一问的结局都是写成或丢弃（检查不合格丢弃不算失败），没有可问的（`questions/4`
  给空表）也算做完。否则 `error` 是这一轮最后一次失败的原因：写日记或召回失败（这一问记失败、这一轮到此为止）、
  在问之前失败（`:no_body_state`、现查 World 失败；`asked` 照记）、某一问一条材料都没有（`:no_materials`，这一问记失败，
  后面的问题照问）。Life 只在做完时消耗新经历。
  """
  def write(snapshot) do
    started = System.monotonic_time(:millisecond)
    round = snapshot.round

    questions =
      Reflection.questions(
        Enum.map(snapshot.buildings, & &1["name"]),
        snapshot.people,
        snapshot.names,
        snapshot.new
      )

    asked = Enum.map(questions, & &1["key"])

    Logger.info(
      "npc_reflect cid=#{snapshot.cid} event=start at_ms=#{snapshot.now_ms} trigger_at_ms=#{round.at_ms} " <>
        "score=#{round.score} causes=#{Enum.join(round.causes, ",")} new=#{length(snapshot.new)} " <>
        "asked=#{inspect(asked)}"
    )

    empty = %{written: [], discarded: [], failed: [], reasked: 0, error: nil}

    outcome =
      cond do
        questions == [] ->
          empty

        true ->
          case right_now(snapshot) do
            {:ok, right_now} ->
              ask_all(questions, right_now, snapshot, empty)

            {:error, reason} ->
              Logger.warning(
                "npc_reflect cid=#{snapshot.cid} event=round_failed at_ms=#{snapshot.now_ms} reason=#{reason(reason)}"
              )

              %{empty | error: reason}
          end
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started

    Logger.info(
      "npc_reflect cid=#{snapshot.cid} event=end at_ms=#{snapshot.now_ms} asked=#{length(asked)} " <>
        "written=#{length(outcome.written)} discarded=#{length(outcome.discarded)} " <>
        "failed=#{length(outcome.failed)} reasked=#{outcome.reasked} " <>
        "error=#{reason(outcome.error)} elapsed_ms=#{elapsed_ms}"
    )

    Map.merge(outcome, %{
      at_ms: snapshot.now_ms,
      score: round.score,
      causes: round.causes,
      asked: asked,
      elapsed_ms: elapsed_ms
    })
  end

  @doc """
  把 `write/1` 写成的各条存档到反思库：文档是 `Reflection.archive/3` 的那份，正文前加时刻前缀（`Life.dated/1`）。
  `snapshot` 里要 `archive`（反思库的 config）与 `archive_name`（`ensure_bank/2` 的 name）。一条都没写成 → `:none`，
  不发请求；否则 `ensure_bank/2` → `retain/2`，返回 `{:ok, retain 的结果}` 或 `{:error, 原因}`。不重试。
  """
  def archive(_snapshot, %{written: []}), do: :none

  def archive(snapshot, %{written: written, at_ms: at_ms}) do
    adapter = snapshot.adapter

    documents =
      for %{question: question, entry: entry} <- written do
        document = Reflection.archive(question, at_ms, entry["journal"])
        %{document | "text" => Life.dated(document)}
      end

    result =
      with {:ok, _} <- adapter.ensure_bank(snapshot.archive, snapshot.archive_name),
           do: adapter.retain(snapshot.archive, documents)

    ids = inspect(Enum.map(documents, & &1["id"]))

    case result do
      {:ok, retained} ->
        Logger.info(
          "npc_reflect cid=#{snapshot.cid} event=archived bank=#{snapshot.archive.bank} " <>
            "documents=#{ids} facts=#{retained[:facts]}"
        )

        {:ok, retained}

      {:error, reason} ->
        Logger.warning(
          "npc_reflect cid=#{snapshot.cid} event=archive_failed bank=#{snapshot.archive.bank} " <>
            "documents=#{ids} reason=#{reason(reason)}"
        )

        {:error, reason}
    end
  end

  # 此刻一块：身体状态还没收到就不渲染（这一轮失败）；我的建筑在不在现查 World。
  defp right_now(%{observation: %{self: %{body_state: nil}}}), do: {:error, :no_body_state}

  defp right_now(snapshot) do
    with {:ok, views} <- Life.standing(snapshot.buildings, snapshot.context),
         do: {:ok, Mind.right_now(snapshot.observation, views)}
  end

  # 按 `questions/4` 的次序一问一问写；写成的立即并进 latest，后面的问题在“之前的想法”里看得到它。
  defp ask_all(questions, right_now, snapshot, outcome) do
    system = Reflection.system_prompt(snapshot.character)

    {outcome, _latest} =
      Enum.reduce_while(questions, {outcome, snapshot.latest}, fn question, {outcome, latest} ->
        key = question["key"]
        started = System.monotonic_time(:millisecond)
        result = ask(question, latest, right_now, system, snapshot)
        elapsed_ms = System.monotonic_time(:millisecond) - started
        line = "npc_reflect cid=#{snapshot.cid} event=question key=#{inspect(key)}"

        case result do
          {:written, checked, attempts} ->
            Logger.info(
              "#{line} result=written attempts=#{attempts} sentences=#{checked.sentences} elapsed_ms=#{elapsed_ms}"
            )

            entry = %{
              "at_ms" => snapshot.now_ms,
              "journal" => checked.journal,
              "closing" => checked.closing,
              "text" => question["text"]
            }

            written = %{key: key, entry: entry, question: question}

            {:cont,
             {%{
                outcome
                | written: outcome.written ++ [written],
                  reasked: outcome.reasked + attempts - 1
              }, Map.put(latest, key, entry)}}

          {:discarded, reason, attempts} ->
            Logger.warning(
              "#{line} result=discarded attempts=#{attempts} reason=#{reason(reason)} elapsed_ms=#{elapsed_ms}"
            )

            {:cont,
             {%{
                outcome
                | discarded: outcome.discarded ++ [key],
                  reasked: outcome.reasked + attempts - 1
              }, latest}}

          # 材料一条都没有：只是这一问写不了，不是外部请求失败，后面的问题照问。
          {:failed, :no_materials, attempts} ->
            Logger.warning(
              "#{line} result=failed attempts=#{attempts} reason=:no_materials elapsed_ms=#{elapsed_ms}"
            )

            {:cont, {%{outcome | failed: outcome.failed ++ [key], error: :no_materials}, latest}}

          {:failed, reason, attempts} ->
            Logger.warning(
              "#{line} result=failed attempts=#{attempts} reason=#{reason(reason)} elapsed_ms=#{elapsed_ms}"
            )

            # 重问那一次失败的，重问照样计数。
            {:halt,
             {%{
                outcome
                | failed: outcome.failed ++ [key],
                  error: reason,
                  reasked: outcome.reasked + max(attempts - 1, 0)
              }, latest}}
        end
      end)

    outcome
  end

  # 一问：两次召回 → 四块材料 → 写，不合格原样重问一次。返回 {:written, check 的结果, 次数} |
  # {:discarded, 原因, 次数} | {:failed, 原因, 次数}（召回失败、没有材料时次数为 0）。
  defp ask(question, latest, right_now, system, snapshot) do
    with {:ok, first} <- recall(question, Enum.at(@recalls, 0), snapshot),
         {:ok, second} <- recall(question, Enum.at(@recalls, 1), snapshot),
         [_ | _] = happened <- happened(snapshot.recent, first, second, snapshot.now_ms) do
      user =
        Reflection.user_message(question, %{
          right_now: right_now,
          happened: happened,
          thought_before: get_in(latest, [question["key"], "journal"]),
          other_thoughts: others(latest, question["key"], snapshot)
        })

      attempt(snapshot, system, user, length(happened), 1)
    else
      [] -> {:failed, :no_materials, 0}
      {:error, reason} -> {:failed, reason, 0}
    end
  end

  # 一路召回（离线脚本 `recall_bodies`）：问题原文；存档 tags 去掉 kind:reflection 之后非空就按它们 any_strict 过滤，
  # 为空（“自己”）两个键都是 nil（适配器不放进请求体）；时刻参数是这一轮的此刻。
  defp recall(question, {types, max_tokens}, snapshot) do
    {tags, match} =
      case question["tags"] -- ["kind:reflection"] do
        [] -> {nil, nil}
        tags -> {tags, "any_strict"}
      end

    description = %{
      query: question["text"],
      types: types,
      max_tokens: max_tokens,
      tags: tags,
      tags_match: match
    }

    with {:ok, %{results: results}} <-
           snapshot.adapter.recall(snapshot.config, description, snapshot.now_ms),
         do: {:ok, results}
  end

  # “发生过的事”各条正文（离线脚本 `number_items`）：先是还没写进 Hindsight 的经历，再是第一次召回、第二次召回的各条；
  # 召回条目按 id 去重（先出现的留下）。
  defp happened(recent, first, second, now_ms) do
    Enum.map(recent, &Mind.recent_item(&1, now_ms)) ++
      (first
       |> Enum.concat(second)
       |> Enum.uniq_by(& &1["id"])
       |> Enum.map(&Mind.recalled(&1, now_ms)))
  end

  # 其它问题各自最新的日记，次序 建筑（记得的次序）→ 人（关系表的次序）→ 自己（S1-X2 运行前补记第 2 条：含本轮刚写成的）。
  # 只取此刻还在的对象：此刻记得的建筑、此刻关系表里的人、“自己”；持久行 "latest" 里已不在这两张表里的旧对象不进材料
  # （行里留着不删）。条数没有上限：现在一个 NPC 只有一座建筑、一个有关系的人（已知的未设上限处，见 Life 的 moduledoc）。
  defp others(latest, key, snapshot) do
    current =
      Enum.uniq(Enum.map(snapshot.buildings, &("place:" <> &1["name"]))) ++
        Enum.map(snapshot.people, &"person:#{&1}") ++ ["self"]

    for other <- current, other != key, entry = latest[other], do: entry["journal"]
  end

  # 写一次、检查；不合格原样重问一次（每问至多重问一次，不论原因），仍不合格就丢弃。写日记的函数失败即这一问失败。
  defp attempt(snapshot, system, user, items, n) do
    case snapshot.write.(system, user) do
      {:ok, %{text: text}} ->
        case Reflection.check(text, items) do
          {:ok, checked} ->
            {:written, checked, n}

          {:error, reason} when n == 1 ->
            Logger.info("npc_reflect cid=#{snapshot.cid} event=reask reason=#{reason(reason)}")
            attempt(snapshot, system, user, items, 2)

          {:error, reason} ->
            {:discarded, reason, n}
        end

      {:error, reason} ->
        {:failed, reason, n}
    end
  end

  # 日志里的原因：编号列表（如 `{:used_out_of_range, [32, 43]}`）按数字写，不让 inspect 把它当字符列表印成 ~c"…"。
  defp reason(reason), do: inspect(reason, charlists: :as_lists)
end
