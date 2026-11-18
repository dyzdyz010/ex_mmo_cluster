defmodule NpcServer.Life.Hindsight do
  @moduledoc """
  全局系统功能：固定 Hindsight 0.10.3 的无状态 HTTP 适配器。

  config 为 `%{url: 服务根 URL, bank: NPC 独立库}`；可覆盖 `timeout_ms`（单请求，
  缺省 300 秒）、`operation_timeout_ms`（每个后台 operation 总预算，缺省 600 秒）。
  调用由 Life 慢 worker 承担，不阻塞 Body。模型和记忆只是主观派生文档，不能接管 World 数值真值。
  retain 的同步抽取后逐文档检查真实 fact 数；consolidation 的待办在 operations/status 中可见。
  原始 HTTP 错误体、URL、异常信息和 LLM trace 都不进入返回值或日志。

  召回一路一次请求，调用方给出一路的描述（问句、可选的 tags 过滤、类型、是否偏好 observation、
  token 上限，见 `recall/3`）；召回结果在本模块边界规范化一次（正文、类型、事件时间 `at_ms`、tags），
  调用方不再解析 Hindsight 的原始时间串。retain 的每条经历可带 tags，原样写进 Hindsight 的 item。
  建库时除 bank 自身的 mission 外还写两条抽取 / 巩固 mission（`ensure/2`），依据是离线测量 S1-L
  （`.demo/observe/npc-slice1-20261112/s1l/`）：两条 mission 让抽取出的事实与 observation 都是第一人称、
  保留次数与“没发生什么”。反思的存档库只要 bank 存在（`ensure_bank/2`），不写这两条 mission、不建认识文档
  （内容规范 §10.12 的 R2）。

  一个 Life 会用到不止一个 bank（经历库、反思库），失败日志 `npc_hindsight_failed` 因此带 `bank=`。

  ## 交互召回与后台取材使用各自的 httpc profile

  `:httpc` 缺省 profile 对每个 host 只开少量持久连接，并且有新请求时**优先排进正忙的会话队列**而不是
  另开连接（OTP `httpc_manager:select_session/4`，见召回隔离决策稿 §2 S4）。选择在等一路召回（交互式，
  10 秒预算），而 retain / refresh / status 是没人在等的后台请求（一次 11–49 秒）；两者共用缺省 profile 时，
  召回会排在后台请求后面，实测 25 次召回超时里有 13 次是这个原因（同稿 §1、E1 实验：缺省 profile 10,001 ms
  超时且请求从未发出，独立 profile 7.7 ms 返回）。

  交互召回和 CLI 的 `context/2` 走交互 profile，反思及日计划的取材走后台召回 profile（D-1b）。
  建库、写入、刷新、状态查询走缺省 profile。请求体和各调用方的超时预算沿用原值。
  两个召回 profile 由 `NpcServer.Application` 在监督树之前起、应用停止时停。采用缺省参数，
  由 inets 的监督保证 manager 重启后仍使用相同参数（决策稿 S4、S5）。
  """
  require Logger

  @recall_profiles %{
    interactive: :npc_hindsight_recall,
    background: :npc_hindsight_background_recall
  }

  @truth "Subjective memory; not current numeric world truth."

  # bank 的 mission：建库 / 更新 bank 时随 PUT 写入。
  @bank_mission "My first-person builder journal. Preserve event history and evolving subjective beliefs. " <>
                  @truth

  # 抽取与巩固 mission：建库后经 PATCH /config 写入。
  # 出处：S1-L 离线测量（`.demo/observe/npc-slice1-20261112/s1l/plan.md`）。
  # 与离线测过的文本只有一处差异：离线版是 `of Garen, a character in a game world`，产品里不写死角色名，
  # 改成 `of a character in a game world`；这一处改动没有离线测过。
  @retain_mission "These are the first-person memories of a character in a game world. " <>
                    "Write every fact in the first person (\"I\"), never as \"the user\" or \"the assistant\". " <>
                    "Keep people's names together with their actor id exactly as written, " <>
                    "for example \"Corvin (actor 920628760578)\". " <>
                    "Keep counts and times. " <>
                    "Keep statements that something did not happen (for example \"nobody came near the hut\") as facts in their own right. " <>
                    "Do not treat me as a separate entity called \"assistant\" or \"user\". " <>
                    "Write in English."

  # 出处：同上（S1-L plan.md 的 observations_mission，原文未改）。
  @observations_mission "Consolidate my memories into first-person observations (\"I\"). " <>
                          "When several memories repeat the same activity, say how many times it happened and what did or did not happen during them. " <>
                          "Keep an event that happened only once or twice as its own observation; do not fold it into the majority. " <>
                          "Keep names with their actor ids. " <>
                          "Write in English."

  # 召回描述里可选的请求字段；值为 nil 的不进请求体。
  @recall_options [:tags, :tags_match, :types, :prefer_observations, :max_tokens]
  @default_recall_max_tokens 2048
  @queries [
    {"self", "What kind of builder am I, and what lessons have I learned from my experiences?"},
    {"relationships",
     "Who helped or harmed me, how has my trust in each person changed, and why?"},
    {"world",
     "What do I remember about places and construction sites I depend on? Historical coordinates are memories, not current world truth."},
    {"commitments", "What promises have I made or received, and which are open or fulfilled?"}
  ]

  @doc "四份认识文档的 id，按建立次序（self、relationships、world、commitments）；给模型列认识时用这个次序。"
  def model_ids, do: Enum.map(@queries, &elem(&1, 0))

  @doc "读取指定召回类别的 profile 名，缺省为交互召回。"
  def recall_profile(kind \\ :interactive), do: Map.fetch!(@recall_profiles, kind)

  @doc "为反思或日计划的取材构造后台召回配置，保留库和请求参数。"
  def for_background_recall(config), do: Map.put(config, :recall_kind, :background)

  @doc """
  用于在监督树前起交互与后台召回池，返回 `{:ok, 本次新起的类别列表}`。
  第二池起失败时回滚本次新起的交互池。
  """
  def start_recall_profiles do
    with {:ok, interactive} <- start_recall_profile() do
      case start_recall_profile(:background) do
        {:ok, background} ->
          attempts = [interactive: interactive, background: background]
          {:ok, for({kind, :started} <- attempts, do: kind)}

        error ->
          if interactive == :started, do: stop_recall_profile()
          error
      end
    end
  end

  @doc "关闭指定的召回池，默认关闭两池。对每个池均尝试关闭，并返回最先遇到的错误。"
  def stop_recall_profiles(kinds \\ [:background, :interactive]) do
    kinds
    |> Enum.map(&stop_recall_profile/1)
    |> Enum.find(:ok, &(&1 != :ok))
  end

  @doc """
  以缺省参数启动指定类别的召回池。已经启动返回 `{:ok, :already_started}`，
  其它错误回传给应用启动边界。
  """
  def start_recall_profile(kind \\ :interactive) do
    case :inets.start(:httpc, profile: recall_profile(kind)) do
      {:ok, _pid} -> {:ok, :started}
      {:error, {:already_started, _pid}} -> {:ok, :already_started}
      other -> other
    end
  end

  @doc "停指定类别的召回池。池缺失视同已停止。"
  def stop_recall_profile(kind \\ :interactive) do
    case :inets.stop(:httpc, recall_profile(kind)) do
      :ok -> :ok
      # 实测（OTP 29.1.2）：profile 不在时 `inets:stop/2` 回 `{:error, :not_found}`。
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  @doc """
  只确保 bank 存在：`PUT` bank（`name` 与 bank 自身的 mission），幂等；返回 `{:ok, %{bank: config.bank}}`。
  不写抽取 / 巩固 mission、不建认识文档——反思的存档库（`npc-reflect-<cid>`）只用这一步；经历库用 `ensure/2`，
  它的第一步就是这个。
  """
  def ensure_bank(config, name) do
    with {:ok, _} <- request(config, :put, "", %{name: name, mission: @bank_mission}),
         do: {:ok, %{bank: config.bank}}
  end

  @doc """
  建立 bank（`ensure_bank/2`）、写抽取 / 巩固 mission，并建立缺失的四份认识文档；已有文档不重建、不刷新。

  mission 经 `PATCH /config`（`{"updates": {"retain_mission": …, "observations_mission": …}}`）写入，
  每次 ensure 都写一次（幂等，使既有 bank 也拿到当前文本）；任一步失败则 ensure 失败。
  依据 S1-L 离线测量，文本见本模块的 `@retain_mission` / `@observations_mission`。
  """
  def ensure(config, name) do
    with {:ok, _} <- ensure_bank(config, name),
         {:ok, _} <-
           request(config, :patch, "/config", %{
             updates: %{
               retain_mission: @retain_mission,
               observations_mission: @observations_mission
             }
           }),
         {:ok, _} <- collect(@queries, fn {id, query} -> ensure_model(config, id, query) end) do
      {:ok, %{bank: config.bank}}
    end
  end

  @doc """
  把纯心智经历 id/text/at_ms 映射为稳定文档，单次批量抽取后检查每份文档的 facts。

  经历可带 `"tags"`（字符串列表）；非空时原样写进 Hindsight 的 retain item，供召回按 tags 过滤；
  缺省、nil 或空列表时 item 不带 `tags` 字段。
  """
  def retain(config, episodes) when is_list(episodes) and episodes != [] do
    with {:ok, items} <- collect(episodes, &episode(config, &1)),
         {:ok, %{"success" => true} = response} <-
           request(config, :post, "/memories", %{items: items, async: false}),
         {:ok, documents} <- collect(items, fn item -> document(config, item.document_id) end),
         {:ok, operations} <- operations(config) do
      {:ok,
       %{
         status: :retained,
         retained: length(items),
         facts: Enum.sum(documents),
         documents: Enum.map(items, & &1.document_id),
         usage: response["usage"] || %{},
         operations: operations
       }}
    else
      {:ok, _} -> failure(config, :invalid_response)
      error -> error
    end
  end

  def retain(config, _), do: failure(config, :invalid_episodes)

  @doc "显式后台刷新四份认识并等 operation 完成；决策热路径禁止调用。"
  def refresh(config) do
    with {:ok, operations} <-
           collect(@queries, fn {id, _} ->
             with {:ok, response} <- request(config, :post, "/mental-models/#{id}/refresh", %{}),
                  {:ok, operation} <- completion(config, response),
                  do: {:ok, operation}
           end),
         {:ok, cached} <- models(config) do
      {:ok, Map.put(cached, :operations, operations)}
    end
  end

  @doc "只读四份缓存认识，不触发 refresh；保留 staleness 与刷新时间。"
  def models(config) do
    with {:ok, rows} <-
           collect(@queries, fn {id, _} ->
             with {:ok, row} <- request(config, :get, "/mental-models/#{id}?detail=content"),
                  do: {:ok, {id, row}}
           end) do
      {:ok,
       %{
         models: Map.new(rows, fn {id, row} -> {id, row["content"]} end),
         metadata:
           Map.new(rows, fn {id, row} ->
             {id, Map.take(row, ["is_stale", "last_refreshed_at", "last_refresh_failed_at"])}
           end),
         truth: @truth
       }}
    end
  end

  @doc """
  对当前情境恰好发一次 mid budget 召回（一路），时间锚来自调用方；返回毫秒耗时。

  第二个参数是这一路召回的描述：

      %{query: 问句, tags: [String.t()] | nil, tags_match: String.t() | nil,
        types: [String.t()] | nil, prefer_observations: boolean() | nil,
        max_tokens: pos_integer() | nil}

  只有 `query` 必填；值为 nil 或缺省的键不进请求体，`max_tokens` 缺省 #{@default_recall_max_tokens}，
  `budget` 固定 `"mid"`。字段含义与取值以 Hindsight 的 RecallRequest 为准，本模块不重复校验。
  不是这个形状（包括裸的问句字符串）→ `{:error, :invalid_query}`，不发请求。
  多路召回的并行与合并在调用方（`NpcServer.Life.mind/2`），这里每次只发一路。

  返回的 `results` 在这里规范化一次，每条是（字符串键，沿用现有调用方读 `"text"` 的形状）：
  `%{"id", "text", "type", "at_ms", "tags"}`。`at_ms` 是 `occurred_start`（没有则 `mentioned_at`）
  解析成的 Unix 毫秒，两者都没有为 nil；时间串不是带时区的 ISO 8601 时整次召回失败
  （`{:error, :invalid_response}`），不静默丢弃。
  """
  def recall(config, %{query: query} = description, now_ms) when is_binary(query) do
    started = System.monotonic_time(:millisecond)

    with {:ok, timestamp} <- timestamp(config, now_ms),
         {:ok, %{"results" => rows}} when is_list(rows) <-
           request(
             config,
             :post,
             "/memories/recall",
             recall_body(description, timestamp),
             recall_profile(Map.get(config, :recall_kind, :interactive))
           ),
         {:ok, results} <- collect(rows, &recalled(config, &1)) do
      {:ok,
       %{
         results: results,
         latency_ms: System.monotonic_time(:millisecond) - started,
         truth: @truth
       }}
    else
      {:ok, _} -> failure(config, :invalid_response)
      error -> error
    end
  end

  def recall(config, _, _), do: failure(config, :invalid_query)

  @doc "只读 facts、最近 100 个后台操作和按操作聚合的 token，用于 CLI/observe；不返回原始 trace。"
  def status(config) do
    with {:ok, stats} <- request(config, :get, "/stats"),
         {:ok, operations} <- operations(config),
         {:ok, usage} <- page(config, "/llm-requests", "items", 200) do
      totals =
        Enum.reduce(usage, %{}, fn item, acc ->
          key = item["scope"] || item["operation"] || "unknown"

          Map.update(acc, key, usage(item), fn previous ->
            Map.merge(previous, usage(item), fn _, a, b -> a + b end)
          end)
        end)

      {:ok, %{stats: stats, operations: operations, usage: totals}}
    end
  end

  defp usage(item),
    do: %{
      requests: 1,
      input_tokens: item["input_tokens"] || 0,
      output_tokens: item["output_tokens"] || 0,
      failed: if(item["status"] in [nil, "success"], do: 0, else: 1)
    }

  defp episode(config, %{"id" => id, "text" => text, "at_ms" => at} = episode)
       when is_binary(id) and id != "" and is_binary(text) and text != "" do
    with {:ok, at} <- timestamp(config, at),
         {:ok, tags} <- episode_tags(config, episode["tags"]) do
      {:ok, Map.merge(%{document_id: id, content: text, timestamp: at}, tags)}
    end
  end

  defp episode(config, _), do: failure(config, :invalid_episodes)

  # 返回要并入 retain item 的字段：有 tags 才有 `tags` 键。
  defp episode_tags(_config, tags) when tags in [nil, []], do: {:ok, %{}}

  defp episode_tags(config, [_ | _] = tags) do
    if Enum.all?(tags, &(is_binary(&1) and &1 != "")),
      do: {:ok, %{tags: tags}},
      else: failure(config, :invalid_episodes)
  end

  defp episode_tags(config, _), do: failure(config, :invalid_episodes)

  defp recall_body(description, timestamp) do
    # 注意 `false` 是合法值（prefer_observations: false），只剔除 nil。
    optional =
      for key <- @recall_options,
          {:ok, value} <- [Map.fetch(description, key)],
          value != nil,
          into: %{},
          do: {key, value}

    Map.merge(
      %{
        query: description.query,
        budget: "mid",
        max_tokens: @default_recall_max_tokens,
        query_timestamp: timestamp
      },
      optional
    )
  end

  # 把 Hindsight 的一条召回结果规范化；时间串或 tags 形状不对时显式失败。
  defp recalled(config, %{} = row) do
    with {:ok, at_ms} <- occurred_ms(config, row["occurred_start"] || row["mentioned_at"]),
         {:ok, tags} <- recalled_tags(config, row["tags"]) do
      {:ok,
       %{
         "id" => row["id"],
         "text" => row["text"],
         "type" => row["type"],
         "at_ms" => at_ms,
         "tags" => tags
       }}
    end
  end

  defp recalled(config, _), do: failure(config, :invalid_response)

  defp occurred_ms(_config, nil), do: {:ok, nil}

  defp occurred_ms(config, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> {:ok, DateTime.to_unix(at, :millisecond)}
      _ -> failure(config, :invalid_response)
    end
  end

  defp occurred_ms(config, _), do: failure(config, :invalid_response)

  defp recalled_tags(_config, nil), do: {:ok, []}

  defp recalled_tags(config, tags) when is_list(tags),
    do:
      if(Enum.all?(tags, &is_binary/1),
        do: {:ok, tags},
        else: failure(config, :invalid_response)
      )

  defp recalled_tags(config, _), do: failure(config, :invalid_response)

  defp timestamp(config, ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> {:ok, DateTime.to_iso8601(at)}
      _ -> failure(config, :invalid_timestamp)
    end
  end

  defp timestamp(config, _), do: failure(config, :invalid_timestamp)

  defp document(config, id) do
    with {:ok, response} <- request(config, :get, "/documents/" <> segment(id)) do
      case response["memory_unit_count"] do
        n when is_integer(n) and n > 0 -> {:ok, n}
        0 -> failure(config, :empty_facts)
        _ -> failure(config, :invalid_response)
      end
    end
  end

  defp ensure_model(config, id, query) do
    case request(config, :get, "/mental-models/#{id}?detail=content") do
      {:ok, row} ->
        {:ok, row}

      {:error, {:http_status, 404}} ->
        with {:ok, response} <-
               request(config, :post, "/mental-models", %{
                 id: id,
                 name: id,
                 source_query: query <> " " <> @truth,
                 max_tokens: 800,
                 trigger: %{refresh_after_consolidation: false}
               }),
             {:ok, operation} <- completion(config, response),
             do: {:ok, operation}

      error ->
        error
    end
  end

  defp completion(config, %{"operation_id" => id}) when is_binary(id) do
    deadline =
      System.monotonic_time(:millisecond) + Map.get(config, :operation_timeout_ms, 600_000)

    poll(config, id, deadline)
  end

  defp completion(config, _), do: failure(config, :invalid_response)

  defp poll(config, id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      failure(config, :operation_timeout)
    else
      bounded =
        Map.put(config, :timeout_ms, min(remaining, Map.get(config, :timeout_ms, 300_000)))

      poll_response(config, id, deadline, request(bounded, :get, "/operations/" <> segment(id)))
    end
  end

  defp poll_response(config, id, deadline, {:ok, operation}) do
    case operation["status"] do
      "completed" ->
        {:ok, Map.take(operation, ["operation_id", "status", "completed_at"])}

      status when status in ["pending", "processing"] ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          failure(config, :operation_timeout)
        else
          Process.sleep(min(remaining, Map.get(config, :poll_interval_ms, 1000)))
          poll(config, id, deadline)
        end

      status when status in ["failed", "cancelled", "not_found"] ->
        failure(config, {:operation_failed, status})

      _ ->
        failure(config, :invalid_response)
    end
  end

  defp poll_response(config, _, deadline, {:error, :timeout}) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: failure(config, :operation_timeout),
      else: failure(config, :timeout)
  end

  defp poll_response(_, _, _, error), do: error

  defp operations(config) do
    with {:ok, %{"operations" => rows}} when is_list(rows) <-
           request(config, :get, "/operations?limit=100&offset=0") do
      {:ok,
       Enum.map(
         rows,
         &Map.take(&1, [
           "id",
           "operation_id",
           "status",
           "task_type",
           "operation_type",
           "created_at",
           "completed_at"
         ])
       )}
    else
      {:ok, _} -> failure(config, :invalid_response)
      error -> error
    end
  end

  defp page(config, path, field, limit, offset \\ 0, acc \\ []) do
    with {:ok, %{^field => rows, "total" => total}} when is_list(rows) and is_integer(total) <-
           request(config, :get, "#{path}?limit=#{limit}&offset=#{offset}") do
      next = offset + length(rows)

      cond do
        next >= total -> {:ok, acc ++ rows}
        rows == [] -> failure(config, :invalid_response)
        true -> page(config, path, field, limit, next, acc ++ rows)
      end
    else
      {:ok, _} -> failure(config, :invalid_response)
      error -> error
    end
  end

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # 发一次请求。`profile` 为 nil 时走 httpc 缺省 profile（建库、retain、刷新、状态这些后台请求）；
  # 召回传所属类别的 profile（原因见 moduledoc 末节）。
  defp request(config, method, path, body \\ nil, profile \\ nil) do
    url =
      String.trim_trailing(config.url, "/") <>
        "/v1/default/banks/" <> segment(config.bank) <> path

    request =
      if body == nil,
        do: {String.to_charlist(url), []},
        else: {String.to_charlist(url), [], ~c"application/json", Jason.encode!(body)}

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    timeout = Map.get(config, :timeout_ms, 300_000)

    result =
      try do
        :httpc.request(
          method,
          request,
          [timeout: timeout, connect_timeout: timeout, ssl: ssl, autoredirect: false],
          [body_format: :binary],
          profile || :default
        )
      catch
        # 专用 profile 不在（没起、被停、inets 停了）：httpc 在调它的 manager 时退出。只把这一类折成显式失败，
        # 其它退出照旧上抛（代码缺陷不在这里吞）。不再先做一次 `get_options` 预检——那是一次到 manager 的
        # infinity 调用，manager 卡住时预检自己会挂住，而且每次召回都多一个来回。
        :exit, reason ->
          if profile != nil and profile_absent?(reason),
            do: {:error, {:profile_not_started, profile}},
            else: exit(reason)
      end

    case result do
      {:ok, {{_, status, _}, _, response}} when status in 200..299 ->
        case Jason.decode(response) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> failure(config, :invalid_response)
        end

      {:ok, {{_, status, _}, _, _}} ->
        failure(config, {:http_status, status})

      {:error, :timeout} ->
        failure(config, :timeout)

      {:error, {:profile_not_started, _} = reason} ->
        failure(config, reason)

      {:error, _} ->
        failure(config, :transport_error)
    end
  end

  # `GenServer.call` 到点/对端不在时的退出形状；httpc 内部用的是 `:gen_server.call`。
  defp profile_absent?(:noproc), do: true
  defp profile_absent?(:shutdown), do: true
  defp profile_absent?(:normal), do: true
  defp profile_absent?({reason, _detail}), do: profile_absent?(reason)
  defp profile_absent?(_), do: false

  # 失败一律经这里：打一行带 bank 的日志（经历库与反思库要分得清），返回 `{:error, reason}`。
  defp failure(config, reason) do
    Logger.warning("npc_hindsight_failed bank=#{config.bank} reason=#{inspect(reason)}")
    {:error, reason}
  end
end
