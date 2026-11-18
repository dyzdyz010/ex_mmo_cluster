Code.require_file("../support/keep_alive_stub.exs", __DIR__)

defmodule NpcServer.NpcRecallIsolationTest do
  @moduledoc """
  只测试：交互召回、反思与规划的后台取材、其余后台 Hindsight 请求分别走 `NpcServer.Http` 的交互 / 后台车道，
  同一主机上的慢后台请求不挡交互召回（召回隔离决策稿 D-1、D-1b；Finch 决策稿 T-1）。

  真实 `NpcServer.Http`（Finch）与 JSON 编解码照常运行，只把 Hindsight 对端换成能保持连接、能并发应答的本地替身；
  不验证 Hindsight 本身的检索质量，也不起 World / Scene / Postgres。
  """
  use ExUnit.Case, async: false
  @moduletag :t0

  alias NpcServer.KeepAliveStub
  alias NpcServer.Life.Hindsight
  alias NpcServer.Life.Reflection
  alias NpcServer.Life.Reflection.Round

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

  test "后台取材首路挂起时交互召回先从另一条连接返回" do
    owner = self()
    release = make_ref()
    now_ms = 1_791_676_800_000
    question = Reflection.self_question()
    background_query = question["text"]
    recall_path = "/v1/default/banks/probe/memories/recall"

    url =
      KeepAliveStub.start(fn
        _,
        :post,
        ^recall_path,
        %{"query" => ^background_query, "types" => ["experience", "world"]} ->
          send(owner, {:recall_waiting, self()})

          receive do
            {:release_recall, ^release} -> {200, %{"results" => []}}
          after
            5_000 -> {503, %{}}
          end

        _, :post, ^recall_path, _body ->
          {200, %{"results" => []}}
      end)

    config = %{url: url, bank: "probe", timeout_ms: 5_000}
    snapshot = material_snapshot(config, now_ms)

    # 预热后台车道的连接。httpc 时代交互与后台共享一个池，有了空闲的持久连接后，后续请求会排进该会话；
    # 现在两条车道各有池，交互召回应落在另一条连接上。
    assert {:ok, _} = Round.materials(%{question | "text" => "Warm up"}, [], snapshot)

    assert_received {:http_request, warmed_conn,
                     %{method: :post, path: ^recall_path, body: %{"query" => "Warm up"}}}

    background = Task.async(fn -> Round.materials(question, [], snapshot) end)

    assert_receive {:http_request, ^warmed_conn,
                    %{method: :post, path: ^recall_path, body: %{"query" => ^background_query}}},
                   2_000

    assert_receive {:recall_waiting, responder}

    try do
      assert {:ok, %{results: []}} =
               Hindsight.recall(
                 %{config | timeout_ms: @recall_budget_ms},
                 %{query: "Who is standing beside me?"},
                 now_ms
               )

      assert_received {:http_request, interactive_conn,
                       %{
                         method: :post,
                         path: ^recall_path,
                         body: %{"query" => "Who is standing beside me?"}
                       }}

      assert interactive_conn != warmed_conn
    after
      send(responder, {:release_recall, release})
    end

    assert {:ok, %{happened: [_]}} = Task.await(background)
  end

  test "Hindsight 的各类请求落在所属车道的连接池里" do
    url = fn ->
      KeepAliveStub.start(fn
        _conn, :post, path, _body ->
          if String.ends_with?(path, "/memories"),
            do: {200, %{"success" => true, "items_count" => 1, "usage" => %{}}},
            else: {200, %{"results" => []}}

        _conn, :get, path, _body ->
          if String.contains?(path, "/operations"),
            do: {200, %{"operations" => [], "total" => 0}},
            else: {200, %{"memory_unit_count" => 1}}
      end)
    end

    now_ms = 1_791_676_800_000

    # 每一类各用一个新替身：替身端口只被这一类请求用过，池建在哪个实例就是走了哪条车道。
    interactive = url.()
    config = %{url: interactive, bank: "probe", timeout_ms: 1_000}
    assert {:ok, _} = Hindsight.recall(config, %{query: "q"}, now_ms)
    assert lanes(interactive) == [:interactive]

    background = url.()
    config = %{url: background, bank: "probe", timeout_ms: 1_000}

    assert {:ok, _} =
             Hindsight.recall(Hindsight.for_background_recall(config), %{query: "q"}, now_ms)

    assert lanes(background) == [:background]

    retain = url.()
    config = %{url: retain, bank: "probe", timeout_ms: 1_000}
    assert {:ok, %{retained: 1}} = Hindsight.retain(config, @episodes)
    assert lanes(retain) == [:background]
  end

  # 替身根 URL 在哪几条车道的 HTTP/1 实例里有池。
  defp lanes(url) do
    pool = Finch.Pool.new(url)

    for {lane, instance} <- [
          interactive: NpcServer.Http.InteractiveHttp1,
          background: NpcServer.Http.BackgroundHttp1
        ],
        match?({:ok, _}, Finch.find_pool(instance, pool)),
        do: lane
  end

  defp material_snapshot(config, now_ms) do
    %{
      adapter: Hindsight,
      config: config,
      now_ms: now_ms,
      recent: [%{at_ms: now_ms - 1_000, text: "I set off at dawn."}],
      latest: %{},
      buildings: [],
      people: []
    }
  end
end
