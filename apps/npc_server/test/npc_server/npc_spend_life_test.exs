Code.require_file("../support/life_fixtures.exs", __DIR__)
Code.require_file("../support/http_stub.exs", __DIR__)
Code.require_file("../support/spend_fixtures.exs", __DIR__)

defmodule NpcServer.NpcSpendLifeTest do
  @moduledoc """
  只测试（T3，真实模块集成）：到线之后“只停后台”的链路——真实 `SpendBudget`（真实账本、真实 Hindsight 适配器读回替身服务）
  把结论发布出去，真实 `Life` 在自己的后台触发处读它：刷新槽不起、反思按 `budget_exhausted` 跳过、日计划不扣当日额度，
  retain、选择请求与召回照常；各库自动巩固随之关掉；拨过北京零点后恢复。

  真实的：`SpendBudget`、`Life`（经 `profile.life.spend` 注入 `&SpendBudget.background/0`，同 `NpcServer.Registry` 的生产注入）、
  `ModelUsage`（发送函数注入，回执照常交给额度）、World（`NpcWorld.start/0`，“别人打了我放的一格”经 World 正式入口做出）、
  NpcMemory 与账本（本 VM 独占的 PostgreSQL）。替身：Life 的 Hindsight 适配器（`LifeFixtures.ReflectHindsight`，另把刷新报给测试进程）、
  写作函数（`profile.write_journal`，把每次写作交给测试进程）、额度读回的 Hindsight 服务（`HttpStub`：两库、没有追踪行，PATCH 照收）、
  时钟（Agent，Life 与额度共用，测试拨动）。观察由测试自己发（`Life.observation/2`，S1-X2 第 4 轮的真实原始观察，游戏钟换成用例的值）。

  上限设得很低（$0.001，停止线 90% = 900_000 nano）：一条 1 万入向 token 的产品回执（北京 23:00，非高峰 0.15 美元 / 百万）
  = 1_500_000 nano 即到线。不证明：真实 Hindsight 的巩固开关效果与在途残余（T4）。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import NpcServer.LifeFixtures, only: [damage: 4, reflect_profile: 3]
  import NpcServer.ReflectionFixtures, only: [rawobs: 1]
  import NpcServer.SpendFixtures, only: [env: 1, ms: 1]
  alias NpcServer.{HttpStub, Life, ModelUsage, NpcWorld, Selector, SpendBudget}
  alias NpcServer.Life.DayPlan
  alias NpcServer.SpendBudget.Config

  defmodule SpendHindsight do
    @moduledoc "只测试：`ReflectHindsight` 之上把每次刷新报给测试进程（`{:refreshed, bank}`）。"
    alias NpcServer.LifeFixtures.ReflectHindsight
    defdelegate ensure(config, name), to: ReflectHindsight
    defdelegate ensure_bank(config, name), to: ReflectHindsight
    defdelegate models(config), to: ReflectHindsight
    defdelegate status(config), to: ReflectHindsight
    defdelegate retain(config, documents), to: ReflectHindsight
    defdelegate recall(config, description, now_ms), to: ReflectHindsight

    def refresh(config) do
      send(config.owner, {:refreshed, config.bank})
      ReflectHindsight.refresh(config)
    end
  end

  @plan_fixtures Path.expand("../support/fixtures/day_plan", __DIR__)
  @day 1500

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    DataService.Repo.delete_all("npc_spend_ledger")

    for module <- [Life, SpendBudget] do
      Logger.put_module_level(module, :info)
      on_exit(fn -> Logger.delete_module_level(module) end)
    end

    :ok
  end

  @tag timeout: 120_000
  test "到线：后台只停刷新、反思、日计划，巩固关掉；retain、选择与召回照常；拨过北京零点恢复" do
    fixture = NpcWorld.start()
    cid = System.unique_integer([:positive]) + 100_000
    banks = ["npc-life-#{cid}", "npc-reflect-#{cid}"]

    clock =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> ms("2026-11-18T15:00:00Z") end}, id: :clock)
      )

    now = fn -> Agent.get(clock, & &1) end

    url = HttpStub.start(&serve(banks, &1, &2, &3))

    config =
      Config.load!(env(%{"NPC_LIFE_HINDSIGHT_URL" => url, "NPC_SPEND_LIMIT_USD" => "0.001"}))

    start_supervised!({SpendBudget, config: config, clock: now, poll_ms: :manual})
    assert %{state: :open} = SpendBudget.sync()
    await_patches(banks, true)

    profile =
      self()
      |> reflect_profile(
        %{clock: now, hindsight: SpendHindsight, spend: &SpendBudget.background/0},
        DataService.NpcMemory
      )
      |> Map.put(:activities, activities())

    life = start_life(cid, profile)

    # 开着：写进一条经历、封存写入，之后认识刷新照常起（刷新时刻从没刷过，到点）。
    Life.activity(life, finished(profile, "visit_plaza", :completed))
    assert {:ok, %{status: :started}} = Life.flush(cid)
    assert_receive {:retained, "npc-life-" <> _, [_]}, 5000
    assert_receive {:refreshed, "npc-life-" <> _}, 5000
    await_life(cid, &(&1.job == nil))

    # 到线：一条真实的产品回执（选择位置的形状）把当日总额推过停止线。
    log =
      capture_log(fn ->
        {_, %{input_tokens: 10_000}} = select(fn _, _ -> usage(10_000) end)
        assert %{state: :paused, reason: :limit} = SpendBudget.observe()
      end)

    assert log =~ ~r/npc_spend day=2026-11-18 .*state=paused reason=limit/
    assert {:paused, %{day: ~D[2026-11-18], reason: :limit}} = SpendBudget.background()
    await_patches(banks, false)

    # 刷新：经历照写（retain 照调），写完到点的刷新不起；CLI 刷新显式拒绝。
    Agent.update(clock, &(&1 + 11 * 60_000))

    log =
      capture_log(fn ->
        Life.activity(life, finished(profile, "guard_hut", :completed))
        assert {:ok, %{status: :started}} = Life.flush(cid)
        assert_receive {:retained, "npc-life-" <> _, [_]}, 5000
        await_life(cid, &(&1.job == nil and &1.cache_dirty))
      end)

    assert log =~ "npc_spend_refused cid=#{cid} kind=refresh day=2026-11-18"
    refute_received {:refreshed, _}
    assert {:error, {:budget_exhausted, ~D[2026-11-18]}} = Life.refresh(cid)
    refute_receive {:refreshed, _}, 200

    # 日计划与反思：有观察、有经历、到点，但都不起；当日额度不扣，写作一次也没调。
    log =
      capture_log(fn ->
        frame(life, 720)
        damage(fixture.world, cid, 1, {4, 64, 8})

        await_life(cid, fn observed ->
          observed.reflection.counts["skipped"] >= 1 and observed.plan.row["event_waiting"]
        end)

        frame(life, 721)
        Life.observe(cid)
      end)

    assert log =~ "npc_spend_refused cid=#{cid} kind=plan day=2026-11-18"
    assert log =~ "npc_spend_refused cid=#{cid} kind=reflect day=2026-11-18"
    assert log =~ ~r/npc_reflect cid=#{cid} event=skipped .*reason=budget_exhausted/
    # 每个 NPC 每种每天只一行。
    assert length(Regex.scan(~r/npc_spend_refused cid=#{cid} kind=plan /, log)) == 1
    refute_received {:write, _, _, _}

    {:ok, observed} = Life.observe(cid)
    assert observed.plan.row["calls"] == DayPlan.new()["calls"]
    assert observed.reflection.counts["rounds"] == 0

    assert observed.spend_refused == %{
             refresh: ~D[2026-11-18],
             plan: ~D[2026-11-18],
             reflect: ~D[2026-11-18]
           }

    # 交互照常：选择请求照发，召回照调。
    {_, %{input_tokens: 10}} =
      select(fn _, _ ->
        send(self(), :selection_sent)
        usage(10)
      end)

    assert_received :selection_sent
    assert {:ok, _} = Life.mind(cid, [%{query: "Who is near?"}])
    assert_received {:recall, "npc-life-" <> _, %{query: "Who is near?"}}

    # 拨过北京零点：读回一轮即换日，后台开，两库巩固打开，刷新与日计划恢复。
    Agent.update(clock, fn _ -> ms("2026-11-18T16:05:00Z") end)
    assert %{state: :open, day: ~D[2026-11-19]} = SpendBudget.sync()
    assert SpendBudget.background() == :open
    await_patches(banks, true)

    assert {:ok, %{status: :started}} = Life.refresh(cid)
    assert_receive {:refreshed, "npc-life-" <> _}, 5000
    await_life(cid, &(&1.job == nil))

    frame(life, 722)
    assert_receive {:write, worker, _system, _user}, 10_000
    send(worker, {:reply, {:error, :timeout}})
  end

  # --- 夹具 ---

  defp serve(banks, :get, "/v1/default/banks?" <> _, nil),
    do: {200, %{"banks" => Enum.map(banks, &%{"bank_id" => &1}), "total" => length(banks)}}

  defp serve(_banks, :get, "/v1/default/banks/" <> _, nil),
    do: {200, %{"items" => [], "total" => 0}}

  defp serve(_banks, :patch, "/v1/default/banks/" <> rest, _body) do
    [bank, "config"] = String.split(rest, "/")
    {200, %{"bank_id" => bank}}
  end

  # 等到两库都收到给定的巩固开关（其间的读回请求跳过）。
  defp await_patches(banks, enabled, seen \\ MapSet.new()) do
    if MapSet.equal?(seen, MapSet.new(banks)) do
      :ok
    else
      receive do
        {:http_request,
         %{
           method: :patch,
           path: "/v1/default/banks/" <> rest,
           body: %{"updates" => %{"enable_auto_consolidation" => ^enabled}}
         }} ->
          [bank, "config"] = String.split(rest, "/")
          await_patches(banks, enabled, MapSet.put(seen, bank))

        {:http_request, _} ->
          await_patches(banks, enabled, seen)
      after
        5000 -> flunk("没等到巩固开关 #{enabled}：已收到 #{inspect(MapSet.to_list(seen))}")
      end
    end
  end

  # 选择位置的一次模型请求（DeepSeek chat completions 形状），经真实 ModelUsage。
  defp select(send_fn),
    do:
      ModelUsage.request(
        %{url: "http://127.0.0.1:9/chat", model: "deepseek-flash", lane: :interactive},
        %{},
        %{cid: 7, operation: :activity_selection, api: :openai},
        send_fn
      )

  defp usage(prompt),
    do:
      {:ok,
       %{
         "model" => "deepseek-flash",
         "usage" => %{"prompt_tokens" => prompt, "completion_tokens" => 0}
       }}

  defp start_life(cid, profile) do
    context = %{cid: cid, name: nil, scene_id: 1, router: NpcWorld.Route}

    life =
      start_supervised!(%{
        id: {:life, cid},
        start: {Life, :start_link, [self(), context, profile]}
      })

    await_life(cid, &match?(%{cache: %{}, job: nil}, &1))
    life
  end

  defp await_life(cid, ready) do
    NpcWorld.await(
      fn ->
        case Life.observe(cid) do
          {:ok, observed} -> ready.(observed)
          _ -> false
        end
      end,
      15_000
    )
  end

  # 一帧观察：S1-X2 第 4 轮那一刻的真实原始观察，游戏钟换成 `@day` 与给定的日内分钟。
  defp frame(life, minute) do
    observation = rawobs(4)

    Life.observation(life, %{
      observation
      | world_time: %{observation.world_time | day: @day, minute_of_day: minute}
    })
  end

  # 一项活动结束时 Runtime 交给 Life 的经历：经 Selector 的产品函数做出（选定 → 结局 → 经历）。
  defp finished(profile, name, result) do
    selection = %{
      activity: name,
      trigger: "start",
      confidence: 0.6,
      latency_ms: 1,
      recall_ms: 1,
      model: "test"
    }

    {_trigger, state} =
      Selector.new() |> Selector.chose(selection, profile, 0) |> Selector.ended(result)

    Selector.experience(state, profile)
  end

  # 词表：S1-R7 的候选（同 `npc_life_day_plan_integration_test.exs`）。
  defp activities do
    for %{"name" => name, "criterion" => criterion} <-
          Path.join(@plan_fixtures, "activities.json") |> File.read!() |> Jason.decode!(),
        do: %{name: name, criterion: criterion, place_name: nil}
  end
end
