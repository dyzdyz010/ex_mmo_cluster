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

  花费额度（`NpcServer.SpendBudget`）的读回也只经本模块：`list_banks/2` 列库、`llm_requests/3` 按时间窗读 LLM 追踪行并在这里
  规范化一次（四项 token 按 `SpendBudget.Price.tokens/1` 校验——与产品回执同一份规则）、`set_auto_consolidation/2` 按库开关自动巩固。

  ## 交互召回与后台请求走不同的出站车道

  选择在等一路召回（交互式，10 秒预算），而 retain / refresh / status 是没人在等的后台请求（一次 11–49 秒）。
  两者若共用一条连接队列，召回会排在后台请求后面（召回隔离决策稿 §1、E1：httpc 缺省 profile 下 10,001 ms 超时
  且请求从未发出）。所以本模块按请求类别给 `NpcServer.Http` 的车道：交互召回和 CLI 的 `context/2` 走 `:interactive`，
  反思及日计划的取材（`for_background_recall/1`）与建库、写入、刷新、状态查询走 `:background`
  （Finch 决策稿 D-2）。车道的连接池、取连接上限与超时契约都在 `NpcServer.Http`；请求体和各调用方的超时预算沿用原值。
  """
  require Logger

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

  @doc "为反思或日计划的取材构造后台召回配置（走后台车道），保留库和请求参数。"
  def for_background_recall(config), do: Map.put(config, :recall_kind, :background)

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
             Map.get(config, :recall_kind, :interactive)
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

  @doc """
  只读 facts、最近 100 个后台操作和按操作聚合的 token，用于 CLI/observe；不返回原始 trace。
  每个操作的用量是 `requests`、`failed` 与 `tokens/1` 的四项之和（思考与命中单列，与花费额度的计量口径同一份读法）。
  """
  def status(config) do
    with {:ok, stats} <- request(config, :get, "/stats"),
         {:ok, operations} <- operations(config),
         {:ok, usage} <- page(config, &request(config, :get, &1), "/llm-requests", "items", 200) do
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
    do:
      Map.merge(tokens(item), %{
        requests: 1,
        failed: if(item["status"] in [nil, "success"], do: 0, else: 1)
      })

  @doc """
  Hindsight 一条 LLM 追踪行（`GET …/llm-requests` 的 item）的四项 token：`input_tokens`（含命中）、`cached_tokens`（命中）、
  `output_tokens`（OpenAI 兼容通道**不含**思考，Hindsight 0.10.3 `providers/openai_compatible_llm.py:467-476`）、
  `thoughts_tokens`（思考）。追踪里缺省的分项是 null，按 0 计。只读计数，不校验——要当计量真值的读法见 `llm_requests/3`。
  """
  def tokens(row),
    do: %{
      input_tokens: row["input_tokens"] || 0,
      cached_tokens: row["cached_tokens"] || 0,
      output_tokens: row["output_tokens"] || 0,
      thoughts_tokens: row["thoughts_tokens"] || 0
    }

  @doc """
  列出 bank id 含 `query`（大小写不敏感的子串，Hindsight 的 `q`）的全部库：`GET /v1/default/banks?q=&limit=100&offset=k`
  读到 `total` 为止，返回 `{:ok, [bank_id]}`。`config` 只要 `url`（可带 `timeout_ms`），不用 `bank`。
  Hindsight 按最近写入排序，翻页期间有写入时同一库可能出现两次或漏掉一次；调用方（花费额度的读回，每周期一轮）下一轮会再列。
  """
  def list_banks(config, query) do
    get = fn path -> logged(config, fetch(config, :get, path, nil, :background)) end

    with {:ok, rows} <-
           page(config, get, "/v1/default/banks?" <> URI.encode_query(%{q: query}), "banks", 100) do
      collect(rows, fn
        %{"bank_id" => id} when is_binary(id) -> {:ok, id}
        _ -> failure(config, :invalid_response)
      end)
    end
  end

  # 读回的页大小：每行带完整对话（见 `llm_requests/3`），所以比 Hindsight 的上限 500 小。
  @llm_page 100

  @doc """
  读这个库（`config.bank`）`started_at` 落在 `[from_ms, to_ms)` 里的全部 LLM 追踪行：`GET …/llm-requests?start_date=&end_date=&limit=100&offset=k`
  读到 `total` 为止（Hindsight 最新在前）。每页 100 行（Hindsight 允许到 500）：0.10.3 的每一行都带这次调用完整的
  `input`（消息列表）与 `output`（`engine/llm_trace.py:339-366` 的 `LLMRequestEntry`），一页的字节数随对话长度涨，
  页取小些让单次应答有界；实际页字节数留 T4 量。每行在这里规范化一次（对话内容不取）：

      %{id: 行 id, model: 模型名或 nil, operation: 操作名或 nil, started_at_ms:, ended_at_ms:,
        tokens: %{input:, cached:, output:, thoughts:}}

  行 id 必须是字符串、两个时刻必须是带时区的 ISO 8601；四项 token 缺省（null）按 0，再经 `SpendBudget.Price.tokens/1`
  校验（非负整数、命中不多于输入——与产品回执同一份规则）。任一行不合格整次读失败（`{:error, :invalid_response}`），不静默丢行；
  日志带库名与行 id（`npc_hindsight_failed bank= reason=:invalid_response row=`，不打印行的内容）。库不存在 → `{:error, :not_found}`
  （不打失败日志，由调用方按“跳过”处理）；其余失败同本模块其它请求（打 `npc_hindsight_failed`）。
  """
  def llm_requests(config, from_ms, to_ms) do
    query = URI.encode_query(%{start_date: iso_ms(from_ms), end_date: iso_ms(to_ms)})

    get = fn path ->
      case fetch(config, :get, bank_path(config, path), nil, :background) do
        {:error, {:http_status, 404}} -> {:error, :not_found}
        result -> logged(config, result)
      end
    end

    with {:ok, rows} <- page(config, get, "/llm-requests?" <> query, "items", @llm_page),
         do: collect(rows, &llm_row(config, &1))
  end

  @doc """
  打开或关掉这个库（`config.bank`）的自动巩固：`PATCH /config` `{"updates": {"enable_auto_consolidation": enabled}}`，幂等
  （Hindsight 按 jsonb 合并，不冲掉 `ensure/2` 写的两条 mission）。返回 `{:ok, %{bank:, enabled:}}`。关掉之后 retain 不再
  把巩固入队、补漏扫描跳过这个库；已入队的巩固照跑（决策稿 §7）。
  """
  def set_auto_consolidation(config, enabled) when is_boolean(enabled) do
    with {:ok, _} <-
           request(config, :patch, "/config", %{
             updates: %{enable_auto_consolidation: enabled}
           }),
         do: {:ok, %{bank: config.bank, enabled: enabled}}
  end

  defp llm_row(config, %{"id" => id, "started_at" => started, "ended_at" => ended} = row)
       when is_binary(id) do
    t = tokens(row)

    with {:ok, started_ms} <- unix_ms(started),
         {:ok, ended_ms} <- unix_ms(ended),
         true <- is_binary(row["model"]) or row["model"] == nil,
         true <- is_binary(row["operation"]) or row["operation"] == nil,
         {:ok, tokens} <-
           NpcServer.SpendBudget.Price.tokens(%{
             input: t.input_tokens,
             cached: t.cached_tokens,
             output: t.output_tokens,
             thoughts: t.thoughts_tokens
           }) do
      {:ok,
       %{
         id: id,
         model: row["model"],
         operation: row["operation"],
         started_at_ms: started_ms,
         ended_at_ms: ended_ms,
         tokens: tokens
       }}
    else
      _ -> invalid_row(config, row)
    end
  end

  defp llm_row(config, row), do: invalid_row(config, row)

  # 不合格的追踪行：日志带库名与行 id（id 不是字符串记 `-`；过长截到 64 个字符），不打印行的内容。
  defp invalid_row(config, row) do
    id =
      case row do
        %{"id" => id} when is_binary(id) -> inspect(String.slice(id, 0, 64))
        _ -> "-"
      end

    failure(config, :invalid_response, " row=#{id}")
  end

  defp unix_ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> {:ok, DateTime.to_unix(at, :millisecond)}
      _ -> :error
    end
  end

  defp unix_ms(_), do: :error

  defp iso_ms(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

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

  # 按 offset 翻页读到 `total`：`get` 发一页的 GET（参数是带查询串的路径），`path` 可以已带查询串。
  defp page(config, get, path, field, limit, offset \\ 0, acc \\ []) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"

    with {:ok, %{^field => rows, "total" => total}} when is_list(rows) and is_integer(total) <-
           get.("#{path}#{separator}limit=#{limit}&offset=#{offset}") do
      next = offset + length(rows)

      cond do
        next >= total -> {:ok, acc ++ rows}
        rows == [] -> failure(config, :invalid_response)
        true -> page(config, get, path, field, limit, next, acc ++ rows)
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

  # 对这个库（`config.bank`）发一次请求，失败打日志。召回给出所属车道（交互或后台），其余请求（建库、retain、刷新、状态、
  # 用量读回、巩固开关）都是后台车道（原因见 moduledoc 末节）。
  defp request(config, method, path, body \\ nil, lane \\ :background),
    do: logged(config, fetch(config, method, bank_path(config, path), body, lane))

  defp bank_path(config, path), do: "/v1/default/banks/" <> segment(config.bank) <> path

  defp logged(config, {:error, reason}), do: failure(config, reason)
  defp logged(_config, result), do: result

  # 发一次请求（`path` 是服务根之下的完整路径），不打日志：`{:ok, JSON 对象}` 或 `{:error, 原因}`。
  defp fetch(config, method, path, body, lane) do
    url = String.trim_trailing(config.url, "/") <> path

    {headers, body} =
      if body == nil,
        do: {[], nil},
        else: {[{"content-type", "application/json"}], Jason.encode!(body)}

    result =
      NpcServer.Http.send_request(
        lane,
        method,
        url,
        headers,
        body,
        Map.get(config, :timeout_ms, 300_000)
      )

    case result do
      {:ok, status, response} when status in 200..299 ->
        case Jason.decode(response) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, :invalid_response}
        end

      {:ok, status, _} ->
        {:error, {:http_status, status}}

      {:error, reason} when reason in [:timeout, :pool_timeout] ->
        {:error, reason}

      {:error, _} ->
        {:error, :transport_error}
    end
  end

  # 失败一律经这里：打一行带 bank 的日志（经历库与反思库要分得清；列库请求没有 bank，记 `-`），返回 `{:error, reason}`。
  # `detail` 是附在行尾的可诊断字段（如不合格追踪行的 ` row=`），不放内容。
  defp failure(config, reason, detail \\ "") do
    Logger.warning(
      "npc_hindsight_failed bank=#{Map.get(config, :bank, "-")} reason=#{inspect(reason)}" <>
        detail
    )

    {:error, reason}
  end
end
