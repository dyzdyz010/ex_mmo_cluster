Code.require_file("../support/http_stub.exs", __DIR__)
Code.require_file("../support/spend_fixtures.exs", __DIR__)

defmodule NpcServer.NpcSpendBudgetTest do
  @moduledoc """
  只测试（T2，真实模块集成）：花费额度的 owner `NpcServer.SpendBudget` 的计量链路——产品回执累加、Hindsight 用量增量读回
  不重不漏（游标、回看、分页、库不存在、读失败、连续读不回）、未定价、重启从账本恢复、跨北京零点归日。

  真实的：`SpendBudget`、`ModelUsage`（发送函数注入，回执照常经 `finish` 交给额度）、Hindsight 适配器与出站 HTTP、账本
  （`DataService.NpcSpend`，本 VM 独占的 PostgreSQL）。替身：Hindsight 服务（`HttpStub`，按 Hindsight 0.10.3 源码的语义回放：
  列库按 `q` 子串过滤、`llm-requests` 按 `started_at ∈ [start_date, end_date)` 过滤、最新在前、`limit` / `offset` 分页；追踪行的
  字段同 M-4 导出 `hindsight-llm.json` 的真实行）；时钟（Agent，测试拨动）；读回不按定时器，用 `sync/0` 驱动（`poll_ms: :manual`）。
  故障注入（只在点名的用例里）：账本替身 `FlakyLedger`（默认转给真实 `DataService.NpcSpend`，点名的操作抛
  `DBConnection.ConnectionError`——数据库断开时 Repo 抛的同一种异常）；读回适配器替身 `CrashingHindsight`（列库即崩，造 worker 的 `:DOWN`）。
  “零点由定时器换日”一例按真实流逝的时钟走（不拨动、不 `sync`）。

  价：每行 / 每条回执都是入 1000（命中 200）、出 100 + 思考 50（回执的出 150 已含推理），高峰 421_200 nano，非高峰一半（手算见
  `@row_nano`）。不证明：到线后 Life 的拒绝点（T3）、真实 Hindsight 与真实模型（T4）。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import NpcServer.SpendFixtures, only: [env: 1, ms: 1]
  alias NpcServer.{HttpStub, ModelUsage, SpendBudget}
  alias NpcServer.SpendBudget.Config

  defmodule FlakyLedger do
    @moduledoc """
    只测试：账本替身。默认把每个调用转给真实的 `DataService.NpcSpend`；`fail/1` 点名的操作改为抛
    `DBConnection.ConnectionError`（数据库断开时 Repo 抛的同一种异常）。开关放在 `:persistent_term`（调用发生在 SpendBudget 进程里）。
    """
    @key {__MODULE__, :failing}

    def fail(ops), do: :persistent_term.put(@key, MapSet.new(ops))

    def prune(before), do: call(:prune, [before])
    def day_totals(day), do: call(:day_totals, [day])
    def bank_watermarks(since), do: call(:bank_watermarks, [since])
    def insert_new(rows), do: call(:insert_new, [rows])

    defp call(op, args) do
      if MapSet.member?(:persistent_term.get(@key, MapSet.new()), op),
        do: raise(DBConnection.ConnectionError, "测试注入：数据库断开"),
        else: apply(DataService.NpcSpend, op, args)
    end
  end

  defmodule CrashingHindsight do
    @moduledoc "只测试：读回适配器替身，列库即崩（读回 worker 因此 `:DOWN`）。"
    def list_banks(_config, _query), do: raise("测试注入：读回 worker 崩溃")
  end

  # 高峰：800 × 0.3 + 200 × 0.006 + 150 × 1.2（美元 / 百万 token）= 421.2 微美元。
  @row_nano 421_200
  @off_peak_nano 210_600
  # 北京 10:00，高峰。
  @t0 "2026-11-18T02:00:00Z"

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    DataService.Repo.delete_all("npc_spend_ledger")
    FlakyLedger.fail([])
    Logger.put_module_level(SpendBudget, :info)
    on_exit(fn -> Logger.delete_module_level(SpendBudget) end)
    :ok
  end

  test "真实 ModelUsage 回执逐条累加进当日产品花费并落账；没有用量的回执不计" do
    clock = clock(@t0)
    start_budget(hindsight(%{}), clock)

    for _ <- 1..2 do
      assert {_, %{input_tokens: 1000, cache_read_input_tokens: 200}} =
               ModelUsage.request(endpoint(), %{}, scope(), fn _, _ -> response() end)
    end

    assert {_, nil} =
             ModelUsage.request(endpoint(), %{}, scope(), fn _, _ -> {:error, :timeout} end)

    assert %{state: :open, nano: %{product: 842_400, hindsight: 0, total: 842_400}} =
             SpendBudget.observe()

    assert [{"product", "activity_selection", "deepseek-flash", 421_200}] ==
             ledger()
             |> Enum.map(&{&1.source, &1.operation, &1.model, &1.nano_usd})
             |> Enum.uniq()

    assert length(ledger()) == 2
    assert SpendBudget.background() == :open
  end

  test "两库 653 行（经历库每页 100、650 行七页）各计一次；名字带 npc- 的无关库不读；首轮给两库打开巩固，第二轮不重计也不再 PATCH" do
    base = ms("2026-11-18T01:00:00Z")
    life = for i <- 1..650, do: row("life-#{i}", base + i * 1000)
    reflect = for i <- 1..3, do: row("reflect-#{i}", base + i * 1000)

    url =
      hindsight(%{
        "npc-life-7" => life,
        "npc-reflect-7" => reflect,
        "npc-probe-9" => [row("probe-1", base)]
      })

    start_budget(url, clock(@t0))

    assert %{nano: %{hindsight: hindsight}, hindsight_read: :ok, consolidation: :ok} =
             SpendBudget.sync()

    assert hindsight == 653 * @row_nano
    requests = drain()

    # 每页 100（追踪行带完整对话内容，页不能大；见 `Life.Hindsight.llm_requests/3`）。
    assert [first | _] = pages = reads(requests, "npc-life-7")

    assert Enum.map(pages, &{&1["limit"], &1["offset"]}) ==
             for(k <- 0..6, do: {"100", "#{k * 100}"})

    # 没有游标、账本也没有这个库的行：从当日北京零点往回多读 10 分钟，到这一轮开始的时刻为止。
    assert {first["start_date"], first["end_date"]} ==
             {"2026-11-17T15:50:00.000Z", "2026-11-18T02:00:00.000Z"}

    assert [%{"offset" => "0"}] = reads(requests, "npc-reflect-7")
    assert [] == reads(requests, "npc-probe-9")
    assert Enum.sort(patches(requests)) == [{"npc-life-7", true}, {"npc-reflect-7", true}]

    assert %{nano: %{hindsight: ^hindsight}} = SpendBudget.sync()
    assert patches(drain()) == []
    assert length(ledger()) == 653
  end

  test "回看窗口：重叠的旧行不重计，新行与开始早于上次终点的迟到行各计一次" do
    clock = clock(@t0)
    a = row("a", ms("2026-11-18T01:50:00Z"))
    b = row("b", ms("2026-11-18T01:55:00Z"))
    {state, url} = hindsight_state(%{"npc-life-7" => [a, b]})
    start_budget(url, clock)
    assert %{nano: %{hindsight: 842_400}} = SpendBudget.sync()
    drain()

    advance(clock, 60_000)
    c = row("c", ms("2026-11-18T02:00:30Z"))

    # 迟到：01:59 开始、100 秒后结束，上一轮（终点 02:00）读的时候还没写进追踪。
    d = row("d", ms("2026-11-18T01:59:00Z"), 100_000)
    Agent.update(state, &Map.put(&1, "npc-life-7", [a, b, c, d]))

    assert %{nano: %{hindsight: hindsight}} = SpendBudget.sync()
    assert hindsight == 4 * @row_nano
    assert [read] = reads(drain(), "npc-life-7")

    assert {read["start_date"], read["end_date"]} ==
             {"2026-11-18T01:50:00.000Z", "2026-11-18T02:01:00.000Z"}

    assert ledger() |> Enum.map(& &1.source_id) |> Enum.sort() == ~w(a b c d)
  end

  test "库不存在跳过；读失败游标不动、恢复后不重不漏；连续 30 分钟读不回即按无法计量停后台" do
    clock = clock(@t0)
    a = row("a", ms("2026-11-18T01:30:00Z"))
    {state, url} = hindsight_state(%{"npc-life-7" => [a], "npc-reflect-7" => {:status, 404}})
    start_budget(url, clock)

    log =
      capture_log(fn ->
        assert %{hindsight_read: :ok, state: :open, nano: %{hindsight: @row_nano}} =
                 SpendBudget.sync()
      end)

    assert log =~ "npc_spend_bank_missing bank=npc-reflect-7"
    Agent.update(state, &Map.put(&1, "npc-life-7", {:status, 500}))

    advance(clock, 10 * 60_000)

    log =
      capture_log(fn ->
        assert %{hindsight_read: {:failed, 1}, state: :open, hindsight_age_ms: 600_000} =
                 SpendBudget.sync()
      end)

    assert log =~ "npc_spend_read_failed bank=npc-life-7 reason={:http_status, 500}"

    advance(clock, 20 * 60_000)

    log =
      capture_log(fn ->
        assert %{state: :paused, reason: :unmeasured, hindsight_age_ms: 1_800_000} =
                 SpendBudget.sync()
      end)

    assert log =~ "state=paused reason=unmeasured"

    assert {:paused, %{day: ~D[2026-11-18], reason: :unmeasured}} = SpendBudget.background()
    await_idle()

    # 断档期间新写进追踪的一行；游标还停在 02:00（读失败不动），所以下一轮从 01:50 读起。
    b = row("b", ms("2026-11-18T02:15:00Z"))
    Agent.update(state, &Map.put(&1, "npc-life-7", [a, b]))
    drain()
    advance(clock, 60_000)

    assert %{state: :open, hindsight_read: :ok, nano: %{hindsight: hindsight}} =
             SpendBudget.sync()

    assert hindsight == 2 * @row_nano
    assert SpendBudget.background() == :open
    reads = reads(drain(), "npc-life-7")
    assert List.last(reads)["start_date"] == "2026-11-18T01:50:00.000Z"
    assert ledger() |> Enum.map(& &1.source_id) |> Enum.sort() == ~w(a b)
  end

  test "价目表没有的模型：入账但不计价，按未定价停后台" do
    url = hindsight(%{"npc-life-7" => [row("a", ms("2026-11-18T01:30:00Z"), 1000, "mystery")]})
    start_budget(url, clock(@t0))

    log =
      capture_log(fn ->
        assert %{state: :paused, reason: :unpriced, unpriced: 1, nano: %{hindsight: 0}} =
                 SpendBudget.sync()
      end)

    assert log =~ "npc_spend_unpriced source=hindsight model=mystery day=2026-11-18"
    assert {:paused, %{reason: :unpriced}} = SpendBudget.background()
    assert [%{model: "mystery", nano_usd: nil}] = ledger()
  end

  test "重启：当日总额从账本恢复；各库首个 start_date = 账本游标 − 回看；巩固开关全量再打一轮" do
    clock = clock(@t0)
    a = row("a", ms("2026-11-18T01:30:00Z"))
    b = row("b", ms("2026-11-18T01:40:00Z"))
    start_budget(hindsight(%{"npc-life-7" => [a, b]}), clock)
    SpendBudget.sync()
    ModelUsage.request(endpoint(), %{}, scope(), fn _, _ -> response() end)
    before = SpendBudget.observe()
    assert before.nano.total == 3 * @row_nano

    stop_supervised!(SpendBudget)
    drain()
    start_budget(last_url(), clock)

    assert SpendBudget.observe().nano == before.nano
    advance(clock, 60_000)
    assert %{nano: %{total: total}} = SpendBudget.sync()
    assert total == 3 * @row_nano
    requests = drain()
    assert [read] = reads(requests, "npc-life-7")
    assert read["start_date"] == "2026-11-18T01:30:00.000Z"
    assert patches(requests) == [{"npc-life-7", true}]
  end

  test "跨北京零点：零点后读到的昨天的行计入昨天，今天只计今天的" do
    clock = clock("2026-11-18T15:55:00Z")
    r1 = row("r1", ms("2026-11-18T15:50:00Z"))
    {state, url} = hindsight_state(%{"npc-life-7" => [r1]})
    start_budget(url, clock)
    assert %{day: ~D[2026-11-18], nano: %{hindsight: @off_peak_nano}} = SpendBudget.sync()

    advance(clock, 10 * 60_000)
    # 北京 23:58 开始、23:59:30 结束（昨天）；北京 00:02 开始（今天）。
    r2 = row("r2", ms("2026-11-18T15:58:00Z"), 90_000)
    r3 = row("r3", ms("2026-11-18T16:02:00Z"))
    Agent.update(state, &Map.put(&1, "npc-life-7", [r1, r2, r3]))

    assert %{day: ~D[2026-11-19], nano: %{hindsight: @off_peak_nano}} = SpendBudget.sync()

    assert DataService.NpcSpend.day_totals(~D[2026-11-18]) ==
             %{product: 0, hindsight: 2 * @off_peak_nano, unpriced: 0}
  end

  test "本节点没有活着的 owner（停了、或崩溃后还没起来）：background/0 是无法计量，不是它生前发布的结论" do
    start_budget(hindsight(%{}), clock(@t0))
    assert SpendBudget.background() == :open

    stop_supervised!(SpendBudget)
    assert {:paused, %{reason: :unmeasured, day: nil}} = SpendBudget.background()
  end

  test "启动时账本读不到：不崩，先按无法计量停后台；下一轮读回重试读到即恢复当日总额" do
    clock = clock(@t0)
    start_budget(hindsight(%{}), clock)
    ModelUsage.request(endpoint(), %{}, scope(), fn _, _ -> response() end)
    assert %{state: :open, nano: %{total: @row_nano}} = SpendBudget.observe()
    stop_supervised!(SpendBudget)

    FlakyLedger.fail([:day_totals])

    log =
      capture_log(fn ->
        start_budget(last_url(), clock, ledger: FlakyLedger)
        assert {:paused, %{reason: :unmeasured}} = SpendBudget.background()

        assert %{state: :paused, reason: :unmeasured, ledger: :unloaded, nano: %{total: nil}} =
                 SpendBudget.sync()
      end)

    assert log =~ "npc_spend_ledger_failed op=day_totals reason=DBConnection.ConnectionError"
    assert log =~ "state=paused reason=unmeasured"
    owner = Process.whereis(SpendBudget)

    FlakyLedger.fail([])
    advance(clock, 60_000)

    assert %{state: :open, ledger: :ok, nano: %{total: @row_nano}} = SpendBudget.sync()
    assert SpendBudget.background() == :open
    assert Process.whereis(SpendBudget) == owner
  end

  test "换日时账本读不到：不崩，按无法计量停后台；下一轮读回重试读到即按新的一天恢复" do
    clock = clock("2026-11-18T15:59:00Z")
    start_budget(hindsight(%{}), clock, ledger: FlakyLedger)
    assert %{state: :open, day: ~D[2026-11-18]} = SpendBudget.sync()
    owner = Process.whereis(SpendBudget)

    FlakyLedger.fail([:day_totals])
    advance(clock, 2 * 60_000)

    log =
      capture_log(fn ->
        assert %{state: :paused, reason: :unmeasured, ledger: :unloaded} = SpendBudget.sync()
      end)

    assert log =~ "npc_spend_day_roll from=2026-11-18 to=2026-11-19"
    assert log =~ "npc_spend_ledger_failed op=day_totals reason=DBConnection.ConnectionError"
    assert {:paused, %{reason: :unmeasured, day: ~D[2026-11-19]}} = SpendBudget.background()

    FlakyLedger.fail([])
    advance(clock, 60_000)

    assert %{state: :open, day: ~D[2026-11-19], ledger: :ok} = SpendBudget.sync()
    assert Process.whereis(SpendBudget) == owner
  end

  test "写不进账本：没写进的行照样计入当日总额（花了就是花了），产品继续花到停止线照停" do
    clock = clock(@t0)
    # 停止线 0.001 美元 × 90% = 900_000 nano：第三条回执（3 × 421_200）才到线。
    start_budget(hindsight(%{}), clock,
      ledger: FlakyLedger,
      env: %{"NPC_SPEND_LIMIT_USD" => "0.001"}
    )

    FlakyLedger.fail([:insert_new])

    log =
      capture_log(fn ->
        for _ <- 1..2, do: ModelUsage.request(endpoint(), %{}, scope(), fn _, _ -> response() end)
        assert %{state: :open, unsaved: 2, nano: %{product: 842_400}} = SpendBudget.observe()

        ModelUsage.request(endpoint(), %{}, scope(), fn _, _ -> response() end)

        assert %{state: :paused, reason: :limit, unsaved: 3, nano: %{total: 1_263_600}} =
                 SpendBudget.observe()
      end)

    assert log =~ "npc_spend_unsaved rows=3 reason=DBConnection.ConnectionError"
    assert {:paused, %{reason: :limit}} = SpendBudget.background()
    assert ledger() == []
  end

  test "写不进账本持续 30 分钟按无法计量停；写回成功后每行只计一次" do
    clock = clock(@t0)
    start_budget(hindsight(%{}), clock, ledger: FlakyLedger)
    FlakyLedger.fail([:insert_new])

    ModelUsage.request(endpoint(), %{}, scope(), fn _, _ -> response() end)
    assert %{state: :open, unsaved: 1, nano: %{product: @row_nano}} = SpendBudget.observe()

    # 读回照常（Hindsight 读得到），只是账本写不进：30 分钟后无法计量。
    advance(clock, 30 * 60_000)

    assert %{
             state: :paused,
             reason: :unmeasured,
             hindsight_read: :ok,
             unsaved: 1,
             unsaved_age_ms: 1_800_000
           } = SpendBudget.sync()

    # 写回：下一条回执入账时两行一起写进，各计一次；再读回一轮也不重计。
    FlakyLedger.fail([])
    ModelUsage.request(endpoint(), %{}, scope(), fn _, _ -> response() end)

    assert %{state: :open, unsaved: 0, unsaved_age_ms: 0, nano: %{product: 842_400}} =
             SpendBudget.observe()

    assert %{nano: %{product: 842_400}} = SpendBudget.sync()
    assert length(ledger()) == 2
  end

  test "读回 worker 崩溃：按这一轮列库失败计，调用方照样拿到回复、不卡住；连续 30 分钟即无法计量" do
    clock = clock(@t0)
    start_budget("http://127.0.0.1:9", clock, hindsight: CrashingHindsight)

    log =
      capture_log(fn ->
        assert %{hindsight_read: {:failed, :list}, running: false, state: :open} =
                 SpendBudget.sync()
      end)

    assert log =~ "npc_spend_read_failed bank=- reason={:crashed, :worker_failed}"

    advance(clock, 30 * 60_000)

    assert %{state: :paused, reason: :unmeasured, hindsight_age_ms: 1_800_000, running: false} =
             SpendBudget.sync()
  end

  test "北京零点由定时器换日：不靠 sync、不靠回执" do
    # 时钟从北京 23:59:58 起按真实流逝走，约 2 秒后过零点；定时读回间隔 1 小时，期间不会再起读回。
    base = ms("2026-11-18T15:59:58Z")
    started = System.monotonic_time(:millisecond)
    now = fn -> base + System.monotonic_time(:millisecond) - started end
    url = hindsight(%{})
    config = Config.load!(env(%{"NPC_LIFE_HINDSIGHT_URL" => url}))

    log =
      capture_log(fn ->
        start_supervised!({SpendBudget, config: config, clock: now, poll_ms: 3_600_000})
        await_idle()

        # 启动时的那一轮读回在零点之前落定（否则这一例证明不了定时器，直接失败）。
        assert %{day: ~D[2026-11-18], state: :open} = SpendBudget.observe()

        await(fn -> SpendBudget.observe().day == ~D[2026-11-19] end)
        assert %{state: :open, running: false} = SpendBudget.observe()
      end)

    assert log =~ "npc_spend_day_roll from=2026-11-18 to=2026-11-19"
  end

  test "产品回执按请求时配置的模型名计价：配置 jev-test、应答写 jev-1.14.0 照价计，不算未定价" do
    rates = %{"miss" => 0.3, "hit" => 0.006, "out" => 1.2}

    start_budget(hindsight(%{}), clock(@t0),
      env: %{
        "NPC_SPEND_PRICES" =>
          Jason.encode!(%{"jev-test" => %{"peak" => rates, "off_peak" => rates}}),
        "NPC_JEV_API" => nil,
        "NPC_JEV_MODEL" => nil,
        "TYPESAFE_MODEL" => "jev-test",
        "NPC_REFLECT_MODEL" => "jev-test"
      }
    )

    # Answers 形状（TypeSafe）：1000 × 0.3 + 150 × 1.2（美元 / 百万 token）= 480 微美元。
    ModelUsage.request(
      %{url: "http://127.0.0.1:9/answers", model: "jev-test", lane: :interactive},
      %{},
      %{cid: 7, operation: :activity_selection, api: :answers},
      fn _, _ ->
        {:ok,
         %{"model" => "jev-1.14.0", "usage" => %{"input_tokens" => 1000, "output_tokens" => 150}}}
      end
    )

    assert %{state: :open, unpriced: 0, nano: %{product: 480_000}} = SpendBudget.observe()
    assert [%{model: "jev-test", nano_usd: 480_000}] = ledger()
  end

  test "产品回执命中多于输入：按非法用量记为未定价（不算出负金额），打日志，后台按未定价停" do
    start_budget(hindsight(%{}), clock(@t0))

    log =
      capture_log(fn ->
        assert {_, nil} =
                 ModelUsage.request(endpoint(), %{}, scope(), fn _, _ ->
                   {:ok,
                    %{
                      "model" => "deepseek-flash",
                      "usage" => %{
                        "prompt_tokens" => 100,
                        "completion_tokens" => 10,
                        "prompt_tokens_details" => %{"cached_tokens" => 200}
                      }
                    }}
                 end)

        assert %{state: :paused, reason: :unpriced, unpriced: 1, nano: %{product: 0}} =
                 SpendBudget.observe()
      end)

    assert log =~ ~r/npc_model_usage_invalid request_id=\d+ operation=activity_selection /

    assert log =~
             "npc_spend_unpriced source=product model=deepseek-flash day=2026-11-18 reason=invalid_usage"

    assert [%{model: "deepseek-flash", nano_usd: nil}] = ledger()
  end

  test "Hindsight 追踪行不合格：这个库这一轮读失败（不丢行入账），日志带库名与行 id、不带内容" do
    good = row("a", ms("2026-11-18T01:30:00Z"))

    bad =
      row("bad-7", ms("2026-11-18T01:31:00Z"))
      |> Map.merge(%{
        "cached_tokens" => 2000,
        "input" => [%{"role" => "user", "content" => "SECRET-DIALOGUE"}]
      })

    start_budget(hindsight(%{"npc-life-7" => [good, bad]}), clock(@t0))

    log =
      capture_log(fn ->
        assert %{hindsight_read: {:failed, 1}, nano: %{hindsight: 0}} = SpendBudget.sync()
      end)

    assert log =~ ~s(npc_hindsight_failed bank=npc-life-7 reason=:invalid_response row="bad-7")
    refute log =~ "SECRET-DIALOGUE"
    assert ledger() == []
  end

  # --- 夹具 ---

  defp clock(iso),
    do: start_supervised!(Supervisor.child_spec({Agent, fn -> ms(iso) end}, id: :clock))

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  # `opts`：`env`（覆盖运行环境）、`ledger`、`hindsight`（替身，缺省为真实模块）。
  defp start_budget(url, clock, opts \\ []) do
    Process.put(:hindsight_url, url)

    config =
      Config.load!(env(Map.merge(%{"NPC_LIFE_HINDSIGHT_URL" => url}, opts[:env] || %{})))

    start_supervised!(
      {SpendBudget,
       [config: config, clock: fn -> Agent.get(clock, & &1) end, poll_ms: :manual] ++
         Keyword.take(opts, [:ledger, :hindsight])}
    )
  end

  defp last_url, do: Process.get(:hindsight_url)

  defp hindsight(banks), do: banks |> hindsight_state() |> elem(1)

  # Hindsight 替身：`banks` 是 `%{bank => [追踪行] | {:status, 状态码}}`，测试经返回的 Agent 改。
  defp hindsight_state(banks) do
    state = start_supervised!(Supervisor.child_spec({Agent, fn -> banks end}, id: :hindsight))
    {state, HttpStub.start(fn method, path, body -> serve(state, method, path, body) end)}
  end

  defp serve(state, :get, "/v1/default/banks?" <> query, nil) do
    %{"q" => q, "limit" => limit, "offset" => offset} = URI.decode_query(query)
    ids = state |> Agent.get(&Map.keys/1) |> Enum.filter(&String.contains?(&1, q)) |> Enum.sort()

    {200,
     %{
       "banks" => ids |> window(offset, limit) |> Enum.map(&%{"bank_id" => &1}),
       "total" => length(ids),
       "limit" => String.to_integer(limit),
       "offset" => String.to_integer(offset)
     }}
  end

  defp serve(state, :get, "/v1/default/banks/" <> rest, nil) do
    [bank, "llm-requests?" <> query] = String.split(rest, "/", parts: 2)
    query = URI.decode_query(query)

    case Agent.get(state, &Map.fetch!(&1, bank)) do
      {:status, code} ->
        {code, %{"detail" => "private detail"}}

      rows ->
        {from, to} = {ms(query["start_date"]), ms(query["end_date"])}

        hits =
          rows
          |> Enum.filter(&(ms(&1["started_at"]) >= from and ms(&1["started_at"]) < to))
          |> Enum.sort_by(&ms(&1["started_at"]), :desc)

        {200,
         %{
           "bank_id" => bank,
           "items" => window(hits, query["offset"], query["limit"]),
           "total" => length(hits),
           "limit" => String.to_integer(query["limit"]),
           "offset" => String.to_integer(query["offset"])
         }}
    end
  end

  defp serve(_state, :patch, "/v1/default/banks/" <> rest, %{
         "updates" => %{"enable_auto_consolidation" => enabled}
       })
       when is_boolean(enabled) do
    [bank, "config"] = String.split(rest, "/")
    {200, %{"bank_id" => bank}}
  end

  defp window(list, offset, limit),
    do: list |> Enum.drop(String.to_integer(offset)) |> Enum.take(String.to_integer(limit))

  # 真实追踪行的形状（M-4 `hindsight-llm.json`），时刻写成 Hindsight 的 `+00:00` 形式。
  defp row(id, started_ms, duration_ms \\ 1000, model \\ "deepseek-flash") do
    %{
      "id" => id,
      "bank_id" => "ignored",
      "operation" => "retain_extract_facts",
      "scope" => "retain",
      "status" => "success",
      "provider" => "openai",
      "model" => model,
      "trace_id" => "trace-" <> id,
      "started_at" => iso(started_ms),
      "ended_at" => iso(started_ms + duration_ms),
      "duration_ms" => duration_ms,
      "input_tokens" => 1000,
      "output_tokens" => 100,
      "cached_tokens" => 200,
      "thoughts_tokens" => 50,
      "total_tokens" => 1100
    }
  end

  defp iso(ms),
    do:
      ms
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.to_iso8601()
      |> String.replace_suffix("Z", "+00:00")

  # 产品回执：DeepSeek chat completions 应答的用量形状（命中在 prompt_tokens_details 里）。
  defp endpoint,
    do: %{url: "http://127.0.0.1:9/chat", model: "deepseek-flash", lane: :interactive}

  defp scope, do: %{cid: 7, operation: :activity_selection, api: :openai}

  defp response,
    do:
      {:ok,
       %{
         "model" => "deepseek-flash",
         "usage" => %{
           "prompt_tokens" => 1000,
           "completion_tokens" => 150,
           "prompt_tokens_details" => %{"cached_tokens" => 200}
         }
       }}

  defp ledger do
    import Ecto.Query, only: [from: 2]

    DataService.Repo.all(
      from(l in "npc_spend_ledger",
        select: %{
          source: l.source,
          source_id: l.source_id,
          operation: l.operation,
          model: l.model,
          nano_usd: l.nano_usd
        }
      )
    )
  end

  defp drain(acc \\ []) do
    receive do
      {:http_request, request} -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp reads(requests, bank) do
    prefix = "/v1/default/banks/#{bank}/llm-requests?"

    for %{method: :get, path: path} <- requests,
        String.starts_with?(path, prefix),
        do: path |> String.replace_prefix(prefix, "") |> URI.decode_query()
  end

  defp patches(requests) do
    for %{method: :patch, path: "/v1/default/banks/" <> rest, body: body} <- requests do
      [bank, "config"] = String.split(rest, "/")
      {bank, body["updates"]["enable_auto_consolidation"]}
    end
  end

  defp await(ready, deadline \\ System.monotonic_time(:millisecond) + 5000) do
    cond do
      ready.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("等待超时")

      true ->
        Process.sleep(10)
        await(ready, deadline)
    end
  end

  defp await_idle(deadline \\ System.monotonic_time(:millisecond) + 5000) do
    cond do
      not SpendBudget.observe().running ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("读回周期一直在途")

      true ->
        Process.sleep(10)
        await_idle(deadline)
    end
  end
end
