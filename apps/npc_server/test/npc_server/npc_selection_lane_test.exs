Code.require_file("../support/keep_alive_stub.exs", __DIR__)

defmodule NpcServer.NpcSelectionLaneTest do
  @moduledoc """
  只测试：活动选择请求走出站的交互车道，不排在同一主机上后台车道的慢请求后面
  （召回隔离决策稿 D-1 的延伸、Finch 决策稿 T-1；实跑证据见 NPC 协调稿“薄片四第二轮”）。

  真实 `NpcServer.Http`（Finch）、`NpcServer.Registry` 构造的 Jev endpoint 与 `NpcServer.Selector.ask/4` 照常运行，
  只把模型对端换成能保持连接、能并发应答的本地替身；不起 World / Scene / Postgres，不发真实模型请求。
  """
  use ExUnit.Case, async: false
  @moduletag :t0
  @moduletag :capture_log

  alias NpcServer.{Http, KeepAliveStub, Selector}
  alias NpcServer.Registry, as: NpcRegistry

  # 替身里慢请求（代表写作 / retain）的时长：必须明显长于"没排队"的选择耗时，排在后面才看得出来。
  @slow_ms 700

  @npc %{
    "who" => "Lin, a builder",
    "persona" => %{
      "traits" => %{"thrifty" => 8, "extraverted" => 3},
      "personal" => "Dislikes crowds."
    },
    "tools" => %{"1" => "镐"},
    "activities" => [
      %{
        "name" => "rest_at_home",
        "criterion" => "Go home and rest.",
        "place" => [2, -3.5],
        "stay_ticks" => 600
      }
    ]
  }

  test "同一主机的慢请求占着后台车道的连接时，选择请求不排在它后面" do
    slow_path = "/slow"

    url =
      KeepAliveStub.start(fn
        _conn, :post, ^slow_path, _body ->
          Process.sleep(@slow_ms)
          {200, %{"ok" => true}}

        _conn, :post, "/warm", _body ->
          {200, %{"ok" => true}}

        _conn, :post, "/jev", _body ->
          {200,
           %{"answers" => %{"activity" => %{"choice" => "rest_at_home", "confidence" => 0.9}}}}
      end)

    # 选择的 endpoint 由正式登记入口构造（TypeSafe 形状，指向替身）。
    profile =
      with_env(
        %{
          "TYPESAFE_API_URL" => url <> "/jev",
          "TYPESAFE_API_KEY" => "test-key",
          "TYPESAFE_MODEL" => "jev-test",
          "NPC_JEV_API" => nil,
          "NPC_JEV_THINKING" => nil,
          "NPC_LIFE_HINDSIGHT_URL" => "http://life.test.invalid",
          "NPC_REFLECT_URL" => "http://127.0.0.1:9/v1/messages",
          "NPC_REFLECT_KEY" => "test-key",
          "NPC_REFLECT_MODEL" => "reflect-test",
          "NPC_REFLECT_API" => nil
        },
        fn ->
          {_brain, profile} = NpcRegistry.brain("npc", @npc)
          profile
        end
      )

    # 写作 / Hindsight 那一侧（没标车道 = 后台车道）：先预热出一条空闲的持久连接，再让慢请求占住它。
    # httpc 时代选择会排进这个会话（OTP `httpc_manager:select_session/4`）——这就是实跑里选择被挡住的前提。
    default = %{url: url <> "/warm", key: NpcServer.Secret.wrap("k"), timeout_ms: 5_000}
    assert {:ok, %{"ok" => true}} = Http.request(default, %{})
    assert_receive {:http_request, warmed_conn, %{path: "/warm"}}

    slow = Task.async(fn -> Http.request(%{default | url: url <> slow_path}, %{}) end)
    # 等慢请求真的到达对端：此刻那条持久连接已被占住。
    assert_receive {:http_request, ^warmed_conn, %{path: ^slow_path}}, 2_000

    started = System.monotonic_time(:millisecond)

    # 候选同产品：登记项生成器（`Offers.registered/2`）给出的那一组。
    question = %{
      state: "I am at home.",
      recall_ms: 0,
      candidates: NpcServer.Offers.registered(profile.activities, [])
    }

    assert {:ok, %{activity: "rest_at_home"}} = Selector.ask(profile, question, "idle")

    elapsed = System.monotonic_time(:millisecond) - started

    assert_received {:http_request, selection_conn, %{path: "/jev"}}

    # 只有选择会在交互车道的实例里为这个替身建池（预热与慢请求没标车道，走后台车道）：
    # 池在哪个实例就是请求走了哪条车道，不依赖“慢请求占住一条连接”这一时序。
    assert {:ok, _} = Finch.find_pool(NpcServer.Http.InteractiveHttp1, Finch.Pool.new(url))

    assert selection_conn != warmed_conn,
           "选择必须走与后台车道不同的连接，否则会排在慢请求后面"

    # 阈值只证明"没排在慢请求后面"：排队就是 ~#{@slow_ms} ms，隔离就是几毫秒；留一半余量防负载抖动。
    assert elapsed < div(@slow_ms, 2),
           "选择被后台车道上的慢请求挡住了（耗时 #{elapsed} ms，慢请求 #{@slow_ms} ms）"

    assert {:ok, %{"ok" => true}} = Task.await(slow, 5_000)
  end

  defp with_env(env, fun) do
    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)

    put = fn values ->
      for {k, v} <- values, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end

    put.(env)

    try do
      fun.()
    after
      put.(previous)
    end
  end
end
