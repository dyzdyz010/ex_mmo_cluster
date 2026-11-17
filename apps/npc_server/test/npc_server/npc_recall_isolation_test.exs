Code.require_file("../support/keep_alive_stub.exs", __DIR__)

defmodule NpcServer.NpcRecallIsolationTest do
  @moduledoc """
  只测试：召回与后台 Hindsight 请求分到不同的 httpc 连接队列（召回隔离决策稿 D-1），以及召回 profile 的起停（D-1 的生命周期）。

  真实 `:httpc` 与 JSON 编解码照常运行，只把 Hindsight 对端换成能保持连接、能并发应答的本地替身；
  不验证 Hindsight 本身的检索质量，也不起 World / Scene / Postgres。
  """
  use ExUnit.Case, async: false
  @moduletag :t0

  alias NpcServer.KeepAliveStub
  alias NpcServer.Life.Hindsight

  # 替身里慢请求的时长与召回的预算：慢请求必须明显长于召回预算，"排在后面"才会表现成超时。
  @slow_ms 700
  @recall_budget_ms 250

  @episodes [
    %{
      "id" => "npc-1-world-a-seq-2",
      "text" => "Brann destroyed my wall.",
      "at_ms" => 1_791_676_800_000,
      "tags" => ["kind:event"]
    }
  ]

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Hindsight.start_recall_profile()
    :ok
  end

  test "召回 profile 起停：重复起视同成功，停掉之后读不到，再起回来" do
    assert {:ok, :already_started} = Hindsight.start_recall_profile()
    assert {:ok, options} = :httpc.get_options(:all, Hindsight.recall_profile())
    assert is_list(options)

    assert :ok = Hindsight.stop_recall_profile()
    assert {:error, _} = :httpc.get_options(:all, Hindsight.recall_profile())

    # 收尾：起回来。`test_helper` 起过它，别的用例还要用。
    assert {:ok, _} = Hindsight.start_recall_profile()
  end

  test "专用 profile 没起来时召回显式失败，不退回缺省 profile" do
    url =
      KeepAliveStub.start(fn _conn, _method, _path, _body -> {200, %{"results" => []}} end)

    assert :ok = Hindsight.stop_recall_profile()
    # 用例失败也要把它起回来（`test_helper` 起过，别的用例还要用）。
    on_exit(fn -> Hindsight.start_recall_profile() end)

    assert {:error, {:profile_not_started, :npc_hindsight_recall}} =
             Hindsight.recall(
               %{url: url, bank: "probe", timeout_ms: 1_000},
               %{query: "q"},
               1_791_676_800_000
             )

    assert {:ok, _} = Hindsight.start_recall_profile()
  end

  test "慢 retain 在途时召回不被排在同一连接队列里" do
    url =
      KeepAliveStub.start(fn
        _conn, :put, _path, _body ->
          {200, %{"id" => "probe"}}

        _conn, :post, path, _body ->
          if String.ends_with?(path, "/memories") do
            # 后台写入：同步、慢（实测 11–49 秒，这里按比例缩到亚秒级）。
            Process.sleep(@slow_ms)
            {200, %{"success" => true, "items_count" => 1, "usage" => %{"input_tokens" => 1}}}
          else
            {200, %{"results" => []}}
          end

        _conn, :get, path, _body ->
          if String.contains?(path, "/operations") do
            {200, %{"operations" => [], "total" => 0}}
          else
            {200, %{"memory_unit_count" => 1}}
          end
      end)

    config = %{url: url, bank: "probe", timeout_ms: 5_000}
    assert {:ok, _} = Hindsight.ensure_bank(config, "NPC 1")

    retain = Task.async(fn -> Hindsight.retain(config, @episodes) end)

    # 等 retain 的写请求真的到达对端：此刻那条连接已被占住。
    assert_receive {:http_request, retain_conn,
                    %{method: :post, path: "/v1/default/banks/probe/memories"}},
                   2_000

    started = System.monotonic_time(:millisecond)

    assert {:ok, %{results: []}} =
             Hindsight.recall(
               %{config | timeout_ms: @recall_budget_ms},
               %{query: "What has happened between me and Brann?"},
               1_791_676_800_000
             )

    elapsed = System.monotonic_time(:millisecond) - started

    assert_receive {:http_request, recall_conn,
                    %{method: :post, path: "/v1/default/banks/probe/memories/recall"}},
                   2_000

    assert recall_conn != retain_conn,
           "召回必须走与后台写入不同的连接，否则会排在同一条队列后面"

    # 阈值只用来证明"没排在慢请求后面"：真被排队就是 ~#{@slow_ms} ms（或直接超时），
    # 真隔离就是几毫秒——留一半的余量，避免冷连接/CI 负载把这条钉住的契约变成 flake。
    assert elapsed < div(@slow_ms, 2),
           "召回被后台写入挡住了（耗时 #{elapsed} ms，慢请求 #{@slow_ms} ms）"

    assert {:ok, %{retained: 1}} = Task.await(retain, 5_000)
  end
end
