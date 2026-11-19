Code.require_file("../support/spend_fixtures.exs", __DIR__)

defmodule NpcServer.NpcSpendPriceTest do
  @moduledoc """
  只测试（T1，算法层）：花费额度的纯函数——价目折算（入未命中 / 命中 / 出 / 思考四项）、高峰与非高峰的定档及两侧边界、
  北京日界、停止线与“无法计量”的判定，以及运行配置的信任边界（`SpendBudget.Config.load!/1`）。不连库、不起进程。

  期望值来自手算（决策稿 §7 的计量口径：一行 = (入 − 命中) × 未命中价 + 命中 × 命中价 + (出 + 思考) × 输出价）与
  DeepSeek 官方价目页（2026-11-19 核对，见 `NpcServer.SpendFixtures`）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  import NpcServer.SpendFixtures, only: [env: 0, env: 1, ms: 1]
  alias NpcServer.SpendBudget.{Config, Price}

  @tokens %{input: 1_000_000, cached: 400_000, output: 100_000, thoughts: 50_000}

  test "手算：入 1,000,000（命中 400,000）、出 100,000、思考 50,000，高峰 362_400_000 nano，非高峰一半" do
    config = Config.load!(env())

    # 高峰：600,000 × 0.3 + 400,000 × 0.006 + 150,000 × 1.2 = 0.18 + 0.0024 + 0.18 = 0.3624 美元。
    assert {:ok, 362_400_000} =
             Price.charge(config, "deepseek-flash", @tokens, ms("2026-11-18T02:00:00Z"))

    assert {:ok, 181_200_000} =
             Price.charge(config, "deepseek-flash", @tokens, ms("2026-11-18T05:00:00Z"))
  end

  test "不足 1 nano 的零头向上取整（宁多计不少计）" do
    rates = %{"miss" => 0.0005, "hit" => 0.0005, "out" => 0.0005}

    config =
      Config.load!(
        env(%{
          "NPC_SPEND_PRICES" => Jason.encode!(%{"m" => %{"peak" => rates, "off_peak" => rates}}),
          "NPC_JEV_MODEL" => "m",
          "NPC_REFLECT_MODEL" => "m"
        })
      )

    at = ms("2026-11-18T02:00:00Z")
    # 每 token 500 pico：1 个 → 0.5 nano → 1；3 个 → 1.5 nano → 2。
    assert {:ok, 1} =
             Price.charge(config, "m", %{input: 1, cached: 0, output: 0, thoughts: 0}, at)

    assert {:ok, 2} =
             Price.charge(config, "m", %{input: 1, cached: 1, output: 1, thoughts: 1}, at)
  end

  test "定档按 UTC 工作日高峰时段（左闭右开）；周末、工作日两段之外都是非高峰" do
    %Config{peak: peak} = Config.load!(env())

    # 2026-11-18 周三、20 周五、21 周六、22 周日、23 周一（下面先核星期，免得手算错日子）。
    assert Enum.map(~w(2026-11-18 2026-11-20 2026-11-21 2026-11-22 2026-11-23), fn day ->
             day |> Date.from_iso8601!() |> Date.day_of_week()
           end) == [3, 5, 6, 7, 1]

    for {iso, tier} <- [
          {"2026-11-18T00:59:59.999Z", :off_peak},
          {"2026-11-18T01:00:00.000Z", :peak},
          {"2026-11-18T03:59:59.999Z", :peak},
          {"2026-11-18T04:00:00.000Z", :off_peak},
          {"2026-11-18T05:59:59.999Z", :off_peak},
          {"2026-11-18T06:00:00.000Z", :peak},
          {"2026-11-18T15:59:59.999Z", :off_peak},
          # 周五：UTC 10:00 是第二段的右端（不含）。
          {"2026-11-20T09:59:59.999Z", :peak},
          {"2026-11-20T10:00:00.000Z", :off_peak},
          # 周六、周日：工作日时段里也是非高峰。
          {"2026-11-21T02:00:00.000Z", :off_peak},
          {"2026-11-22T07:00:00.000Z", :off_peak},
          # 周一：00:59 还是非高峰（周日夜里延续过来），01:00 起高峰。
          {"2026-11-23T00:59:00.000Z", :off_peak},
          {"2026-11-23T01:00:00.000Z", :peak}
        ] do
      assert {iso, Price.tier(peak, ms(iso))} == {iso, tier}
    end

    config = Config.load!(env())

    # 周六 UTC 02:00（北京 10:00）：按非高峰价，正好是工作日同一时刻的一半。
    assert {:ok, 181_200_000} =
             Price.charge(config, "deepseek-flash", @tokens, ms("2026-11-21T02:00:00Z"))

    # 不配高峰时段：每一刻都按高峰（多计，不少计）。
    %Config{peak: :always} = config = Config.load!(env(%{"NPC_SPEND_PEAK_UTC" => nil}))

    assert {:ok, 362_400_000} =
             Price.charge(config, "deepseek-flash", @tokens, ms("2026-11-21T20:00:00Z"))
  end

  test "高峰规则可写多条（分号分隔），星期可写单日；周日到周一跨不了（要拆成两条）" do
    %Config{peak: peak} =
      Config.load!(env(%{"NPC_SPEND_PEAK_UTC" => "sat 00:00-24:00; mon-tue 23:00-24:00"}))

    assert peak == [{6, 6, [{0, 1440}]}, {1, 2, [{1380, 1440}]}]
    assert Price.tier(peak, ms("2026-11-21T23:59:59.999Z")) == :peak
    assert Price.tier(peak, ms("2026-11-22T00:00:00Z")) == :off_peak
    assert Price.tier(peak, ms("2026-11-24T23:00:00Z")) == :peak
    assert Price.tier(peak, ms("2026-11-25T23:00:00Z")) == :off_peak
  end

  test "北京日界：UTC 15:59:59.999 归当天，16:00 归次日" do
    assert Price.day(ms("2026-11-18T15:59:59.999Z")) == ~D[2026-11-18]
    assert Price.day(ms("2026-11-18T16:00:00Z")) == ~D[2026-11-19]
    assert Price.day_start_ms(~D[2026-11-19]) == ms("2026-11-18T16:00:00Z")
    assert Price.next_day_ms(ms("2026-11-18T15:59:59.999Z")) == ms("2026-11-18T16:00:00Z")
    assert Price.next_day_ms(ms("2026-11-18T16:00:00Z")) == ms("2026-11-19T16:00:00Z")
  end

  test "判定：恰等停止线即暂停；停止线优先于未定价，未定价优先于读不回；读不回满 30 分钟才算" do
    open = %{
      total: 99,
      stop: 100,
      unpriced: 0,
      read_age_ms: 0,
      unsaved_age_ms: 0,
      unmeasured_ms: 1_800_000
    }

    assert Price.verdict(open) == :open
    assert Price.verdict(%{open | total: 100}) == {:paused, :limit}
    assert Price.verdict(%{open | unpriced: 1}) == {:paused, :unpriced}
    assert Price.verdict(%{open | total: 100, unpriced: 1}) == {:paused, :limit}
    assert Price.verdict(%{open | read_age_ms: 1_799_999}) == :open
    assert Price.verdict(%{open | read_age_ms: 1_800_000}) == {:paused, :unmeasured}

    assert Price.verdict(%{open | unpriced: 1, read_age_ms: 1_800_000}) ==
             {:paused, :unpriced}

    # 写不进账本：没写进的行已算进总额（停止线照样管用），但连续 30 分钟写不进也算无法计量。
    assert Price.verdict(%{open | unsaved_age_ms: 1_799_999}) == :open
    assert Price.verdict(%{open | unsaved_age_ms: 1_800_000}) == {:paused, :unmeasured}
    assert Price.verdict(%{open | total: 100, unsaved_age_ms: 1_800_000}) == {:paused, :limit}
    # 当日账本还没读到（启动或换日时读失败）：总额未知，无法计量。
    assert Price.verdict(%{open | total: nil}) == {:paused, :unmeasured}
  end

  test "一次调用的四项 token：非负整数且命中不多于输入才合法（产品回执与 Hindsight 追踪行共用这一份）" do
    ok = %{input: 10, cached: 10, output: 0, thoughts: 0}
    assert Price.tokens(ok) == {:ok, ok}

    for bad <- [
          %{ok | cached: 11},
          %{ok | input: -1, cached: 0},
          %{ok | output: -1},
          %{ok | thoughts: 1.5},
          %{ok | input: "10"},
          %{ok | cached: nil}
        ] do
      assert {bad, Price.tokens(bad)} == {bad, :error}
    end
  end

  test "价目表没有的模型、没有模型名的行：未定价" do
    config = Config.load!(env())
    at = ms("2026-11-18T02:00:00Z")
    assert :unpriced = Price.charge(config, "gpt-unknown", @tokens, at)
    assert :unpriced = Price.charge(config, nil, @tokens, at)
  end

  test "Config.load!：合法即类型化；没配 Hindsight 地址即未启用" do
    assert %Config{
             hindsight_url: "http://127.0.0.1:9",
             limit_nano: 65_000_000_000,
             stop_nano: 58_500_000_000,
             peak: [{1, 5, [{60, 240}, {360, 600}]}],
             prices: %{
               "deepseek-flash" => %{
                 peak: %{miss: 300_000, hit: 6_000, out: 1_200_000},
                 off_peak: %{miss: 150_000, hit: 3_000, out: 600_000}
               }
             }
           } = Config.load!(env())

    assert :disabled = Config.load!(%{})
    assert :disabled = Config.load!(env(%{"NPC_LIFE_HINDSIGHT_URL" => nil}))
  end

  test "Config.load!：缺或非法即 raise，消息只点变量名，不带原值" do
    secret = "SECRET-VALUE-7731"

    cases = [
      {"NPC_SPEND_LIMIT_USD", %{"NPC_SPEND_LIMIT_USD" => nil}},
      {"NPC_SPEND_LIMIT_USD", %{"NPC_SPEND_LIMIT_USD" => secret}},
      {"NPC_SPEND_LIMIT_USD", %{"NPC_SPEND_LIMIT_USD" => "0"}},
      {"NPC_SPEND_LIMIT_USD", %{"NPC_SPEND_LIMIT_USD" => "-5"}},
      {"NPC_SPEND_LIMIT_USD", %{"NPC_SPEND_LIMIT_USD" => "0.0000000001"}},
      {"NPC_SPEND_STOP_RATIO", %{"NPC_SPEND_STOP_RATIO" => nil}},
      {"NPC_SPEND_STOP_RATIO", %{"NPC_SPEND_STOP_RATIO" => "1.5"}},
      {"NPC_SPEND_STOP_RATIO", %{"NPC_SPEND_STOP_RATIO" => "0"}},
      {"NPC_SPEND_STOP_RATIO", %{"NPC_SPEND_STOP_RATIO" => secret}},
      {"NPC_SPEND_PRICES", %{"NPC_SPEND_PRICES" => nil}},
      {"NPC_SPEND_PRICES", %{"NPC_SPEND_PRICES" => "{not json " <> secret}},
      {"NPC_SPEND_PRICES", %{"NPC_SPEND_PRICES" => "{}"}},
      {"NPC_SPEND_PRICES",
       %{
         "NPC_SPEND_PRICES" =>
           Jason.encode!(%{secret => %{"peak" => %{"miss" => 1, "hit" => 1, "out" => 1}}})
       }},
      {"NPC_SPEND_PRICES",
       %{
         "NPC_SPEND_PRICES" =>
           Jason.encode!(%{
             "m" => %{
               "peak" => %{"miss" => -1, "hit" => 1, "out" => 1},
               "off_peak" => %{"miss" => 1, "hit" => 1, "out" => 1}
             }
           })
       }},
      {"NPC_SPEND_PRICES",
       %{
         "NPC_SPEND_PRICES" =>
           Jason.encode!(%{
             "m" => %{
               "peak" => %{"miss" => 0.0000001, "hit" => 1, "out" => 1},
               "off_peak" => %{"miss" => 1, "hit" => 1, "out" => 1}
             }
           })
       }},
      {"NPC_SPEND_PEAK_UTC", %{"NPC_SPEND_PEAK_UTC" => "mon-fri 25:00-26:00"}},
      {"NPC_SPEND_PEAK_UTC", %{"NPC_SPEND_PEAK_UTC" => "mon-fri 10:00-09:00"}},
      {"NPC_SPEND_PEAK_UTC", %{"NPC_SPEND_PEAK_UTC" => "mon-fri 00:00-10:00,09:00-12:00"}},
      {"NPC_SPEND_PEAK_UTC", %{"NPC_SPEND_PEAK_UTC" => "fri-mon 01:00-04:00"}},
      {"NPC_SPEND_PEAK_UTC", %{"NPC_SPEND_PEAK_UTC" => "weekdays 01:00-04:00"}},
      {"NPC_SPEND_PEAK_UTC", %{"NPC_SPEND_PEAK_UTC" => "01:00-04:00"}},
      {"NPC_SPEND_PEAK_UTC", %{"NPC_SPEND_PEAK_UTC" => "mon-fri 01:00-04:00;"}},
      {"NPC_SPEND_PEAK_UTC", %{"NPC_SPEND_PEAK_UTC" => secret}},
      {"NPC_SPEND_PEAK_UTC", %{"NPC_SPEND_PEAK_UTC" => ""}},
      {"NPC_LIFE_HINDSIGHT_URL", %{"NPC_LIFE_HINDSIGHT_URL" => "ftp://" <> secret}},
      # 与登记（`NpcServer.Registry`）同一份规则：主机不能为空；`NPC_JEV_API` 认不出的值不猜。
      {"NPC_LIFE_HINDSIGHT_URL", %{"NPC_LIFE_HINDSIGHT_URL" => "http://"}},
      {"NPC_JEV_API", %{"NPC_JEV_API" => secret}},
      {"NPC_REFLECT_MODEL", %{"NPC_REFLECT_MODEL" => secret}},
      {"NPC_JEV_MODEL", %{"NPC_JEV_MODEL" => secret}},
      {"TYPESAFE_MODEL", %{"NPC_JEV_API" => nil, "TYPESAFE_MODEL" => secret}}
    ]

    for {name, overrides} <- cases do
      error = assert_raise ArgumentError, fn -> Config.load!(env(overrides)) end
      assert error.message =~ name, "#{inspect(overrides)} → #{error.message}"
      refute error.message =~ secret
    end
  end
end
