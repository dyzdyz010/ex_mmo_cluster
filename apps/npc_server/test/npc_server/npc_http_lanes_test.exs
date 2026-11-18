Code.require_file("../support/keep_alive_stub.exs", __DIR__)

defmodule NpcServer.NpcHttpLanesTest do
  @moduledoc """
  只测试：`NpcServer.Http` 的两条车道（交互 / 后台）各有自己的 Finch 连接池，取连接排队有显式上限，
  调用方放弃或超时时请求真的被取消，排队时长进 `npc_model_request`（Finch 决策稿 §4 的 T-0、T-2、T-3、T-5）。

  真实 `NpcServer.Http`、Finch / Mint 与 `NpcServer.ModelUsage` 照常运行，只把对端换成能保持连接、能并发应答的
  本地 HTTP/1.1 替身（`NpcServer.KeepAliveStub`）。替身是明文 HTTP/1，所以这里只覆盖 HTTP/1 池；
  HTTP/2（TLS 上的模型主机）的协商由真实冒烟（决策稿 T-4）验证。不起 World / Scene / Postgres，不发真实模型请求。
  全程只用回环 TCP，连接随替身与车道的池一起回收。
  """
  use ExUnit.Case, async: false
  @moduletag :t0

  import ExUnit.CaptureLog

  alias NpcServer.{Http, KeepAliveStub, ModelUsage, Secret}

  # 交互车道取连接的上限（决策稿 D-4 的原创初值）；断言留出调度余量。
  @interactive_pool_timeout_ms 2_000
  # HTTP/1 池每条车道对一个主机的连接上限（同上）。
  @http1_pool_size 8

  test "T-0 两条车道对同一主机各自建池，同一车道复用自己的连接" do
    url = KeepAliveStub.start(fn _conn, :post, _path, _body -> {200, %{"ok" => true}} end)

    for {lane, path} <- [interactive: "/a", background: "/b", interactive: "/c"] do
      assert {:ok, %{"ok" => true}} =
               Http.request(
                 %{url: url <> path, key: Secret.wrap("k"), timeout_ms: 1_000, lane: lane},
                 %{}
               )
    end

    assert_received {:http_request, interactive_conn, %{path: "/a"}}
    assert_received {:http_request, background_conn, %{path: "/b"}}
    assert_received {:http_request, reused_conn, %{path: "/c"}}

    assert interactive_conn != background_conn, "两条车道必须各有自己的连接池"
    assert reused_conn == interactive_conn, "同一车道应复用自己池里空闲的 keep-alive 连接"
  end

  test "T-2 车道的连接全忙时，下一个请求在 pool_timeout 处显式失败且从未发出，用量记录排队失败" do
    owner = self()
    release = make_ref()

    url =
      KeepAliveStub.start(fn
        _conn, :post, "/hold", _body ->
          send(owner, {:holding, self()})

          receive do
            {:release, ^release} -> {200, %{"ok" => true}}
          after
            10_000 -> {503, %{}}
          end

        _conn, :post, "/late", _body ->
          {200, %{"ok" => true}}
      end)

    endpoint = %{
      url: url <> "/hold",
      key: Secret.wrap("k"),
      timeout_ms: 15_000,
      lane: :interactive
    }

    holders = for _ <- 1..@http1_pool_size, do: Task.async(fn -> Http.request(endpoint, %{}) end)

    responders =
      for _ <- 1..@http1_pool_size do
        assert_receive {:holding, responder}, 3_000
        responder
      end

    try do
      started = System.monotonic_time(:millisecond)

      {result, log} =
        with_log([level: :info], fn ->
          ModelUsage.request(
            Map.merge(endpoint, %{url: url <> "/late", model: "lane-probe"}),
            %{},
            %{cid: 7, operation: :select, api: :openai}
          )
        end)

      elapsed = System.monotonic_time(:millisecond) - started

      assert {{:error, :pool_timeout}, nil} = result
      assert elapsed >= @interactive_pool_timeout_ms - 100
      assert elapsed < @interactive_pool_timeout_ms + 1_500

      # 排队失败的请求从未到达对端。
      refute_received {:http_request, _, %{path: "/late"}}

      assert [
               %{"event" => "finished", "status" => "pool_timeout", "lane" => "interactive"} =
                 done
             ] =
               model_events(log, "finished")

      assert is_integer(done["queue_ms"]) and
               done["queue_ms"] >= @interactive_pool_timeout_ms - 100
    after
      for responder <- responders, do: send(responder, {:release, release})
    end

    for holder <- holders, do: assert({:ok, %{"ok" => true}} = Task.await(holder, 5_000))
  end

  test "T-3 请求在途时调用进程被杀，连接随之关闭" do
    owner = self()
    release = make_ref()

    url =
      KeepAliveStub.start(fn _conn, :post, "/hang", _body ->
        send(owner, {:hanging, self()})

        receive do
          {:release, ^release} -> {200, %{"ok" => true}}
        after
          5_000 -> {503, %{}}
        end
      end)

    caller =
      spawn(fn ->
        Http.request(
          %{url: url <> "/hang", key: Secret.wrap("k"), timeout_ms: 10_000, lane: :interactive},
          %{}
        )
      end)

    assert_receive {:http_request, conn, %{path: "/hang"}}, 2_000
    assert_receive {:hanging, responder}

    Process.exit(caller, :kill)

    # 替身只在回完这一笔之后才读得到对端关闭；放它回，再看这条连接是否被客户端关掉（不再保持 keep-alive）。
    send(responder, {:release, release})

    assert_receive {:conn_closed, ^conn}, 1_000
  end

  test "T-3 请求超时返回 :timeout，并关闭已发出那一笔的连接" do
    owner = self()
    release = make_ref()

    url =
      KeepAliveStub.start(fn _conn, :post, "/hang", _body ->
        send(owner, {:hanging, self()})

        receive do
          {:release, ^release} -> {200, %{"ok" => true}}
        after
          5_000 -> {503, %{}}
        end
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             Http.request(
               %{url: url <> "/hang", key: Secret.wrap("k"), timeout_ms: 300, lane: :interactive},
               %{}
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 280 and elapsed < 1_500

    assert_received {:http_request, conn, %{path: "/hang"}}
    assert_receive {:hanging, responder}
    send(responder, {:release, release})

    assert_receive {:conn_closed, ^conn}, 1_000
  end

  test "T-5 模型请求的 finished 事件带车道与取连接的排队时长" do
    url = KeepAliveStub.start(fn _conn, :post, _path, _body -> {200, %{"ok" => true}} end)

    {_, log} =
      with_log([level: :info], fn ->
        ModelUsage.request(
          %{
            url: url,
            key: Secret.wrap("k"),
            timeout_ms: 1_000,
            lane: :interactive,
            model: "lane-probe"
          },
          %{},
          %{cid: 7, operation: :select, api: :openai}
        )
      end)

    assert [%{"status" => "response", "lane" => "interactive", "queue_ms" => queue_ms}] =
             model_events(log, "finished")

    assert is_integer(queue_ms) and queue_ms >= 0

    # 没标车道的 endpoint 走后台车道，事件里照实记。
    {_, log} =
      with_log([level: :info], fn ->
        ModelUsage.request(
          %{url: url, key: Secret.wrap("k"), timeout_ms: 1_000, model: "lane-probe"},
          %{},
          %{cid: 7, operation: :reflect, api: :openai}
        )
      end)

    assert [%{"lane" => "background", "queue_ms" => queue_ms}] = model_events(log, "finished")
    assert is_integer(queue_ms)
  end

  test "协议既不是 http 也不是 https 时显式失败，不发请求" do
    assert {:error, {:unsupported_scheme, "ftp"}} =
             Http.request(
               %{url: "ftp://127.0.0.1/x", key: Secret.wrap("k"), lane: :interactive},
               %{}
             )
  end

  @tag :capture_log
  test "https 带 cacertfile 时用 HTTP/2 实例里按该文件打标签的池；连不上报 :connection_unavailable 而不是排队" do
    # 回环 1 号端口拒绝连接：HTTP/2 池在交互车道的取连接上限内连不上。
    url = "https://127.0.0.1:1/chat/completions"
    path = "/nonexistent/npc-ca.pem"
    pool = Finch.Pool.new(url, tag: {:cacertfile, path})
    instance = NpcServer.Http.InteractiveHttp2

    # 连不上的 HTTP/2 池会在后台退避重连；用完即停，不留到别的用例。
    on_exit(fn -> Finch.stop_pool(instance, pool) end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :connection_unavailable} =
             Http.request(
               %{
                 url: url,
                 key: Secret.wrap("k"),
                 timeout_ms: 1_000,
                 lane: :interactive,
                 cacertfile: path
               },
               %{}
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= @interactive_pool_timeout_ms - 100
    assert elapsed < @interactive_pool_timeout_ms + 1_500

    # 断线的 HTTP/2 池会从请求注册表摘掉自己，按池监督者查：标签池在，同主机的缺省池没起过。
    assert {:ok, 1} = Finch.get_pool_count(instance, pool)
    assert {:error, :not_found} = Finch.get_pool_count(instance, Finch.Pool.new(url))
  end

  defp model_events(log, event) do
    for [_, json] <- Regex.scan(~r/npc_model_request (\{[^\n]+\})/, log),
        decoded = Jason.decode!(json),
        decoded["request_model"] == "lane-probe" and decoded["event"] == event,
        do: decoded
  end
end
