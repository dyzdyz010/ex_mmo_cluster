defmodule NpcServer.SpendBudget do
  @moduledoc """
  全局系统功能：NPC 每天模型花费额度的唯一 owner（每节点一个）——维护“今天（北京自然日）花了多少”与由此得出的
  “后台开还是停”，并让 Hindsight 各库的自动巩固跟着这个结论开关。决策稿：
  `docs/10-active/cross-cutting/2026-11-18-npc-spend-budget-decision.md`（§4 方案、§6 用户已定、§7 实施细节与原创决策）。

  ```mermaid
  flowchart LR
    MU[ModelUsage 回执<br/>record/1] --> SB
    W[读回 worker<br/>每 poll_ms 一轮] -- 追踪行 / 巩固回执 --> SB[SpendBudget<br/>当日总额 · 游标 · 期望巩固]
    W <-- GET banks / llm-requests<br/>PATCH config --> H[(Hindsight)]
    SB -- insert_new / day_totals --> L[(npc_spend_ledger)]
    SB -- persistent_term --> BG[background/0<br/>:open / {:paused, …}]
    BG --> Life[Life 的后台触发处<br/>刷新槽 · 反思 · 日计划]
  ```

  ## 计量

  - **产品**：`NpcServer.ModelUsage` 每次拿到用量就 `record/1`（cast）。完成时刻按本进程的时钟取回执到达的那一刻，开始时刻
    往回推 `duration_ms`；`usage = nil` 的请求不计（残余少计，决策稿 §7）。
  - **Hindsight**：每 `poll_ms`（缺省 60 秒）起一个读回 worker：列 `npc-` 库（只读 `npc-life-*` 与 `npc-reflect-*`），每库读
    `started_at ∈ [游标 − 回看 10 分钟, 本轮开始)` 的全部追踪行（`Life.Hindsight.llm_requests/3`，分页到 `total`）。追踪行在调用结束后
    才写、`started_at` 是倒推的，所以每轮往回多读一段，靠账本的 `unique(source, source_id)` 去重——只把**真正新插入**的行计进总额。
    库不存在跳过（info）；读失败这个库的游标不动（warning），下一轮从原处接着读。
  - 一次调用的金额与归日在 `SpendBudget.Price`（按完成时刻定高峰档与北京日）；价目与上限在 `SpendBudget.Config`（`init` 时校验一次）。
  - 账本（`DataService.NpcSpend`）是累计的唯一真值：重启时从账本恢复当日总额与各库游标（最晚一行的 `started_at`），不另存标志；
    入库失败的行留在内存 `unsaved`，下一次入账时再写（这些行在写进账本之前不计入总额）。账本只留 7 天（原创取值）。

  ## 判定（`SpendBudget.Price.verdict/1`）

  当日总额 ≥ 停止线（上限 × 比例，用户定 $65 × 90%）→ `:limit`；当日有未定价的行 → `:unpriced`；Hindsight 用量连续 30 分钟没读全
  （本轮列库失败或任一库读失败都算没读全）→ `:unmeasured`。后两条是“无法计量即停后台”（原创决策，已报用户）。北京零点换日：
  总额从账本按新的一天重读，判定随之恢复（不广播，Life 在自己的下一次后台触发时读到）。

  结论经 `:persistent_term` 发布（只在状态或日子变化时写一次）：`background/0` 给 `:open` 或
  `{:paused, %{day:, reason:, total_usd:, stop_usd:}}`（金额是转入这个状态那一刻的；实时数见 `observe/0`）。
  拒绝点不在这里：只有 Life 在自己的后台触发处读这个结论（刷新槽、反思、日计划）；选择、说话、召回不过闸门，
  `ModelUsage` 也不拦请求。

  ## 自动巩固

  期望状态 = 后台没停。每轮读回对本轮列出、本进程还没确认过当前期望的库发 `PATCH …/config`（`Life.Hindsight.set_auto_consolidation/2`，
  幂等）；失败的下一轮再发（`consolidation=pending:N`）。期望一变（转停 / 转开）确认集清空并立即起一轮；重启时确认集为空，首轮即全量。
  关掉之后已入队的巩固照跑（残余，T4 量）。

  ## 未启用

  运行环境没配 `NPC_LIFE_HINDSIGHT_URL`（`Config.load!/1` 给 `:disabled`）：不读账本、不读回，`background/0` 一直是
  `{:paused, %{reason: :unmeasured, day: nil, …}}`——没有可读的 Hindsight 就无法计量，不设“未配置即不限”的分支。

  ## 可观测

  一行 `npc_spend day= product_usd= hindsight_usd= total_usd= stop_usd= limit_usd= state= reason= hindsight_read= hindsight_age_ms=
  unpriced= unsaved= consolidation=`：每轮读回结束一行；状态变化时另一行（转停为 warning）。另有 `npc_spend_read_failed`、
  `npc_spend_bank_missing`、`npc_spend_unpriced`（每模型每天一行）、`npc_spend_unsaved`、`npc_spend_day_roll`。
  CLI 经 release RPC 调 `observe/0`（同一组字段，另带 nano 整数）与 `sync/0`（立即读回一轮）。
  """
  use GenServer
  require Logger
  alias NpcServer.SpendBudget.{Config, Price}

  @published {__MODULE__, :background}
  @poll_ms 60_000
  # 每轮往回多读一段（原创取值：Hindsight 单次调用上限 120 秒，追踪行在调用结束后才写）。
  @lookback_ms 600_000
  # 连续多久没读全 Hindsight 用量就按“无法计量”停后台（原创决策，已报用户）。
  @unmeasured_ms 1_800_000
  # 账本保留天数（原创取值）。
  @retention_days 7
  # 读回的单请求超时：没人在等，但一轮读不完不能拖住下一轮。
  @read_timeout_ms 30_000
  @sync_timeout_ms 120_000
  @bank_query "npc-"
  @bank_prefixes ["npc-life-", "npc-reflect-"]

  @type background ::
          :open
          | {:paused,
             %{
               day: Date.t() | nil,
               reason: :limit | :unpriced | :unmeasured,
               total_usd: float(),
               stop_usd: float() | nil
             }}

  @doc """
  由 NPC 监督树启动（在 `NpcServer.BodySupervisor` 之后、`NpcServer.Bootstrap` 之前：任何 NPC 起来之前结论已发布）。
  选项只给测试：`config`（缺省 `Config.load!/0`）、`clock`（Unix 毫秒）、`poll_ms`（正整数或 `:manual`——不起定时器，
  只靠 `sync/0` 与状态变化驱动读回）、`ledger`（缺省 `DataService.NpcSpend`）、`hindsight`（缺省 `NpcServer.Life.Hindsight`）。
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  此刻后台开还是停（读 `:persistent_term`，不进本进程邮箱，Life 每次后台触发都可以调）：`:open` 或
  `{:paused, %{day:, reason:, total_usd:, stop_usd:}}`，`reason` ∈ `:limit | :unpriced | :unmeasured`。
  本节点上从没发布过结论（本进程还没启动过）时同未启用：`{:paused, %{reason: :unmeasured, day: nil, …}}`——没有 owner 就无法计量。
  """
  @spec background() :: background()
  def background, do: :persistent_term.get(@published, paused(nil, :unmeasured, 0, nil))

  @doc """
  记一次产品模型请求的回执（cast，由 `NpcServer.ModelUsage` 在拿到用量时调用）：
  `%{request_id:, cid:, operation:, model:, usage:, duration_ms:}`，`usage` 是 `ModelUsage` 规范化后的用量
  （`input_tokens` 含命中、`output_tokens` 含推理、可选 `cache_read_input_tokens`）。本进程不在时什么也不做。
  """
  def record(receipt), do: GenServer.cast(__MODULE__, {:record, receipt})

  @doc "立即读回一轮（在途的那一轮之后再起一轮），等这一轮入账后返回 `observe/0` 的视图。CLI 与测试用。"
  def sync(timeout \\ @sync_timeout_ms), do: GenServer.call(__MODULE__, :sync, timeout)

  @doc """
  当前视图：`npc_spend` 日志行的各字段（`day`、`product_usd` 等金额串、`state`、`reason`、`hindsight_read`（`:none` 还没读过 /
  `:ok` / `{:failed, 失败库数或 :list}`）、`hindsight_age_ms`、`unpriced`、`unsaved`、`consolidation`（`:unknown` / `:ok` /
  `{:pending, 库数}`））另加 `banks`（上一轮列到的计量库数）、`running`（读回在途）与 `nano`（各金额的 nano-USD 整数）。
  未启用时为 `%{enabled: false, state: :paused, reason: :unmeasured}`。
  """
  def observe, do: GenServer.call(__MODULE__, :observe)

  # --- 进程 ---

  @impl true
  def init(opts) do
    case Keyword.get_lazy(opts, :config, &Config.load!/0) do
      :disabled ->
        publish(paused(nil, :unmeasured, 0, nil))

        Logger.warning(
          "npc_spend state=paused reason=unmeasured detail=disabled_no_hindsight_url"
        )

        {:ok, :disabled}

      %Config{} = config ->
        {:ok, restore(config, opts)}
    end
  end

  # 从账本恢复当日总额与各库游标，发布第一份结论；定时模式下立即读回一轮（确认集为空 → 全量打一轮巩固开关）并排好零点。
  defp restore(config, opts) do
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end)
    ledger = Keyword.get(opts, :ledger, DataService.NpcSpend)
    now = clock.()
    day = Price.day(now)
    ledger.prune(Date.add(day, -@retention_days))
    totals = ledger.day_totals(day)

    s = %{
      config: config,
      clock: clock,
      ledger: ledger,
      hindsight: Keyword.get(opts, :hindsight, NpcServer.Life.Hindsight),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      # 产品回执的 source_id 前缀：ModelUsage 的请求号只在一次启动内唯一。
      boot: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      day: day,
      product: totals.product,
      hindsight_nano: totals.hindsight,
      unpriced: totals.unpriced,
      unpriced_models: MapSet.new(),
      cursors: ledger.bank_watermarks(Date.add(day, -1)),
      # 最近一轮读全 Hindsight 用量的时刻（本轮开始的时刻）；启动时按“刚读过”算。
      read_ok_ms: now,
      read: :none,
      unsaved: %{},
      banks: [],
      desired: nil,
      confirmed: MapSet.new(),
      pending: nil,
      worker: nil,
      # 等“下一轮”的 sync 调用方：nil = 没有人在等下一轮。
      next: nil,
      poll_timer: nil,
      state: nil
    }

    s = evaluate(s)

    if is_integer(s.poll_ms) do
      send(self(), :poll)
      schedule_day_roll(s, now)
    end

    s
  end

  @impl true
  def handle_cast({:record, _receipt}, :disabled), do: {:noreply, :disabled}

  def handle_cast({:record, receipt}, s) do
    s = roll(s)
    now = s.clock.()
    usage = receipt.usage

    tokens = %{
      input: usage.input_tokens,
      cached: Map.get(usage, :cache_read_input_tokens, 0),
      output: usage.output_tokens,
      thoughts: 0
    }

    row =
      ledger_row(s.config, %{
        source: "product",
        source_id: "#{s.boot}-#{receipt.request_id}",
        bank: nil,
        operation: to_string(receipt.operation),
        model: receipt.model,
        started_ms: now - receipt.duration_ms,
        ended_ms: now,
        tokens: tokens
      })

    {:noreply, s |> stash([row]) |> flush() |> evaluate()}
  end

  @impl true
  def handle_call(request, _from, :disabled) when request in [:observe, :sync],
    do: {:reply, %{enabled: false, state: :paused, reason: :unmeasured}, :disabled}

  def handle_call(:observe, _from, s), do: {:reply, view(s), s}

  # 已有一轮在途时，调用方等下一轮（那一轮开始在这次调用之前，不算“立即读回”）；换日引起的转开会当场起一轮，调用方就等它。
  def handle_call(:sync, from, s) do
    before = s.worker
    s = s |> roll() |> evaluate()

    if s.worker != nil and s.worker != before,
      do: {:noreply, update_in(s.worker.waiters, &[from | &1])},
      else: {:noreply, request_cycle(s, [from])}
  end

  @impl true
  def handle_info(:poll, :disabled), do: {:noreply, :disabled}

  def handle_info(:poll, s) do
    s = %{s | poll_timer: nil}
    if s.worker, do: {:noreply, s}, else: {:noreply, s |> roll() |> start_cycle([])}
  end

  def handle_info(:day_roll, s) do
    s = s |> roll() |> evaluate()
    schedule_day_roll(s, s.clock.())
    {:noreply, s}
  end

  def handle_info({:cycle, pid, result}, %{worker: %{pid: pid} = worker} = s) do
    Process.demonitor(worker.ref, [:flush])
    {:noreply, land(%{s | worker: nil}, worker.waiters, result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{worker: %{ref: ref} = worker} = s) do
    result = %{
      now: worker.now,
      listed: {:error, {:crashed, exit_kind(reason)}},
      reads: %{},
      patches: %{},
      desired: worker.desired
    }

    {:noreply, land(%{s | worker: nil}, worker.waiters, result)}
  end

  def handle_info(_message, s), do: {:noreply, s}

  # --- 读回周期 ---

  defp request_cycle(%{worker: nil} = s, waiters), do: start_cycle(s, waiters)
  defp request_cycle(s, waiters), do: %{s | next: (s.next || []) ++ waiters}

  # 起一个读回 worker：本轮要用的东西（游标、期望、确认集）此刻取齐，worker 不回头问本进程。等下一轮的调用方并进这一轮。
  defp start_cycle(s, waiters) do
    now = s.clock.()
    work = cycle(s, now)
    owner = self()
    {pid, ref} = spawn_monitor(fn -> send(owner, {:cycle, self(), work.()}) end)

    worker = %{
      pid: pid,
      ref: ref,
      now: now,
      desired: s.desired,
      waiters: waiters ++ (s.next || [])
    }

    %{s | worker: worker, next: nil}
  end

  defp cycle(s, now) do
    %{hindsight: adapter, cursors: cursors, desired: desired, confirmed: confirmed} = s
    base = %{url: s.config.hindsight_url, timeout_ms: @read_timeout_ms}
    day_start = Price.day_start_ms(Price.day(now))

    fn ->
      case adapter.list_banks(base, @bank_query) do
        {:ok, ids} ->
          banks = ids |> Enum.filter(&metered?/1) |> Enum.uniq()

          reads =
            Map.new(banks, fn bank ->
              from = Map.get(cursors, bank, day_start) - @lookback_ms
              {bank, adapter.llm_requests(Map.put(base, :bank, bank), from, now)}
            end)

          patches =
            for bank <- banks,
                not MapSet.member?(confirmed, bank),
                into: %{},
                do: {bank, adapter.set_auto_consolidation(Map.put(base, :bank, bank), desired)}

          %{now: now, listed: {:ok, banks}, reads: reads, patches: patches, desired: desired}

        {:error, reason} ->
          %{now: now, listed: {:error, reason}, reads: %{}, patches: %{}, desired: desired}
      end
    end
  end

  defp metered?(bank), do: Enum.any?(@bank_prefixes, &String.starts_with?(bank, &1))

  # 一轮的结果入账：游标、读全的时刻、新行（去重入账）、巩固确认，然后判定、写一行日志、回复等这一轮的调用方，
  # 有人等下一轮就接着起，否则排下一次定时读回。
  defp land(s, waiters, result) do
    s = roll(s)

    {s, read} =
      case result.listed do
        {:error, reason} ->
          Logger.warning("npc_spend_read_failed bank=- reason=#{inspect(reason)}")
          {s, {:failed, :list}}

        {:ok, banks} ->
          {s, failed} =
            Enum.reduce(result.reads, {%{s | banks: banks}, 0}, &read_bank(&1, &2, result.now))

          {s, if(failed == 0, do: :ok, else: {:failed, failed})}
      end

    s = %{
      s
      | read: read,
        read_ok_ms: if(read == :ok, do: result.now, else: s.read_ok_ms)
    }

    s =
      s
      |> confirm(result)
      |> flush()
      |> evaluate()

    Logger.info(line(view(s)))
    for from <- waiters, do: GenServer.reply(from, view(s))

    if s.next != nil and s.worker == nil,
      do: start_cycle(s, []),
      else: schedule_poll(s)
  end

  defp read_bank({bank, {:ok, rows}}, {s, failed}, now) do
    rows = Enum.map(rows, &hindsight_row(s.config, bank, &1))
    {%{stash(s, rows) | cursors: Map.put(s.cursors, bank, now)}, failed}
  end

  defp read_bank({bank, {:error, :not_found}}, acc, _now) do
    Logger.info("npc_spend_bank_missing bank=#{bank}")
    acc
  end

  defp read_bank({bank, {:error, reason}}, {s, failed}, _now) do
    Logger.warning("npc_spend_read_failed bank=#{bank} reason=#{inspect(reason)}")
    {s, failed + 1}
  end

  # 巩固开关的回执只在期望没变时算数（在途期间转了停 / 开，这一轮打的是旧期望，确认集已清空，下一轮重打）。
  defp confirm(%{banks: banks} = s, %{desired: desired, patches: patches} = result) do
    confirmed =
      if desired == s.desired do
        for {bank, {:ok, _}} <- patches, reduce: s.confirmed, do: (set -> MapSet.put(set, bank))
      else
        s.confirmed
      end

    pending =
      case result.listed do
        {:ok, _} -> Enum.count(banks, &(not MapSet.member?(confirmed, &1)))
        {:error, _} -> s.pending
      end

    %{s | confirmed: confirmed, pending: pending}
  end

  defp schedule_poll(%{poll_ms: :manual} = s), do: s

  defp schedule_poll(s) do
    if s.poll_timer, do: Process.cancel_timer(s.poll_timer)
    %{s | poll_timer: Process.send_after(self(), :poll, s.poll_ms)}
  end

  defp schedule_day_roll(%{poll_ms: :manual}, _now), do: :ok

  defp schedule_day_roll(_s, now),
    do: Process.send_after(self(), :day_roll, Price.next_day_ms(now) - now)

  # --- 入账与判定 ---

  defp hindsight_row(config, bank, row) do
    t = row.tokens

    ledger_row(config, %{
      source: "hindsight",
      source_id: row.id,
      bank: bank,
      operation: row.operation,
      model: row.model,
      started_ms: row.started_at_ms,
      ended_ms: row.ended_at_ms,
      tokens: %{
        input: t.input_tokens,
        cached: t.cached_tokens,
        output: t.output_tokens,
        thoughts: t.thoughts_tokens
      }
    })
  end

  defp ledger_row(config, call) do
    nano =
      case Price.charge(config, call.model, call.tokens, call.ended_ms) do
        {:ok, nano} -> nano
        :unpriced -> nil
      end

    %{
      source: call.source,
      source_id: call.source_id,
      bank: call.bank,
      operation: call.operation,
      model: call.model,
      day: Price.day(call.ended_ms),
      started_at: DateTime.from_unix!(call.started_ms, :millisecond),
      ended_at: DateTime.from_unix!(call.ended_ms, :millisecond),
      input_tokens: call.tokens.input,
      cached_tokens: call.tokens.cached,
      output_tokens: call.tokens.output,
      thoughts_tokens: call.tokens.thoughts,
      nano_usd: nano
    }
  end

  # 待入账的行按 {source, source_id} 去重（回看会把同一行再读到）。
  defp stash(s, rows) do
    unsaved = Enum.reduce(rows, s.unsaved, &Map.put_new(&2, {&1.source, &1.source_id}, &1))
    %{s | unsaved: unsaved}
  end

  # 写账本：只把真正新插入的行计进总额；失败的整批留在 unsaved，下一次入账再写。
  defp flush(%{unsaved: unsaved} = s) when map_size(unsaved) == 0, do: s

  defp flush(s) do
    case insert(s.ledger, Map.values(s.unsaved)) do
      {:ok, inserted} ->
        Enum.reduce(inserted, %{s | unsaved: %{}}, &count/2)

      {:error, reason} ->
        Logger.warning("npc_spend_unsaved rows=#{map_size(s.unsaved)} reason=#{inspect(reason)}")

        s
    end
  end

  defp insert(ledger, rows) do
    {:ok, ledger.insert_new(rows)}
  rescue
    error -> {:error, error.__struct__}
  end

  # 只累加当日的行；别的日子的行只落账（换日时总额从账本重读）。
  defp count(%{day: day}, %{day: today} = s) when day != today, do: s

  defp count(%{nano_usd: nil} = row, s) do
    if not MapSet.member?(s.unpriced_models, row.model),
      do:
        Logger.warning(
          "npc_spend_unpriced source=#{row.source} model=#{row.model} day=#{row.day}"
        )

    %{s | unpriced: s.unpriced + 1, unpriced_models: MapSet.put(s.unpriced_models, row.model)}
  end

  defp count(%{source: "product", nano_usd: nano}, s), do: %{s | product: s.product + nano}
  defp count(%{nano_usd: nano}, s), do: %{s | hindsight_nano: s.hindsight_nano + nano}

  # 北京零点换日：当日总额与未定价数从账本按新的一天重读，删掉保留期以外的行。
  defp roll(s) do
    day = Price.day(s.clock.())

    if day == s.day do
      s
    else
      s.ledger.prune(Date.add(day, -@retention_days))
      totals = s.ledger.day_totals(day)
      Logger.info("npc_spend_day_roll from=#{s.day} to=#{day}")

      %{
        s
        | day: day,
          product: totals.product,
          hindsight_nano: totals.hindsight,
          unpriced: totals.unpriced,
          unpriced_models: MapSet.new()
      }
    end
  end

  # 判定并在变化时发布；后台开 / 停翻转时期望的巩固状态随之翻转，确认集清空并立即起一轮（启动时那一次不算翻转）。
  defp evaluate(s) do
    verdict =
      Price.verdict(%{
        total: total(s),
        stop: s.config.stop_nano,
        unpriced: s.unpriced,
        read_age_ms: s.clock.() - s.read_ok_ms,
        unmeasured_ms: @unmeasured_ms
      })

    if {verdict, s.day} == s.state do
      s
    else
      published =
        case verdict do
          :open -> :open
          {:paused, reason} -> paused(s.day, reason, total(s), s.config.stop_nano)
        end

      publish(published)
      s = %{s | state: {verdict, s.day}}
      line = line(view(s))
      if verdict == :open, do: Logger.info(line), else: Logger.warning(line)

      desired = verdict == :open

      cond do
        s.desired == nil -> %{s | desired: desired}
        s.desired == desired -> s
        true -> request_cycle(%{s | desired: desired, confirmed: MapSet.new()}, [])
      end
    end
  end

  defp total(s), do: s.product + s.hindsight_nano

  defp paused(day, reason, total, stop),
    do:
      {:paused,
       %{day: day, reason: reason, total_usd: total / 1.0e9, stop_usd: stop && stop / 1.0e9}}

  defp publish(value), do: :persistent_term.put(@published, value)

  # --- 视图与日志 ---

  defp view(s) do
    {state, reason} =
      case s.state do
        {:open, _} -> {:open, nil}
        {{:paused, reason}, _} -> {:paused, reason}
      end

    total = total(s)

    %{
      day: s.day,
      product_usd: usd(s.product),
      hindsight_usd: usd(s.hindsight_nano),
      total_usd: usd(total),
      stop_usd: usd(s.config.stop_nano),
      limit_usd: usd(s.config.limit_nano),
      state: state,
      reason: reason,
      hindsight_read: s.read,
      hindsight_age_ms: s.clock.() - s.read_ok_ms,
      unpriced: s.unpriced,
      unsaved: map_size(s.unsaved),
      consolidation:
        case s.pending do
          nil -> :unknown
          0 -> :ok
          n -> {:pending, n}
        end,
      banks: length(s.banks),
      running: s.worker != nil,
      nano: %{
        product: s.product,
        hindsight: s.hindsight_nano,
        total: total,
        stop: s.config.stop_nano,
        limit: s.config.limit_nano
      }
    }
  end

  defp line(v) do
    "npc_spend day=#{v.day} product_usd=#{v.product_usd} hindsight_usd=#{v.hindsight_usd} " <>
      "total_usd=#{v.total_usd} stop_usd=#{v.stop_usd} limit_usd=#{v.limit_usd} state=#{v.state} " <>
      "reason=#{v.reason || "none"} hindsight_read=#{field(v.hindsight_read)} " <>
      "hindsight_age_ms=#{v.hindsight_age_ms} unpriced=#{v.unpriced} unsaved=#{v.unsaved} " <>
      "consolidation=#{field(v.consolidation)}"
  end

  defp field({kind, detail}), do: "#{kind}:#{detail}"
  defp field(value), do: to_string(value)

  # nano-USD → 6 位小数的美元串（整数运算，不经浮点）。
  defp usd(nano) do
    micro = div(nano, 1000)
    "#{div(micro, 1_000_000)}." <> String.pad_leading("#{rem(micro, 1_000_000)}", 6, "0")
  end

  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_), do: :worker_failed
end
