Code.require_file("../support/http_stub.exs", __DIR__)

defmodule NpcServer.NpcReflectionWriterTest do
  @moduledoc """
  只测试：反思写日记的模型客户端（`NpcServer.Life.Reflection.Writer`）的 HTTP 信任边界。

  契约：发出的请求同离线测量 S1-X2 实际发过的条件（`x-api-key`、`anthropic-version`、JSON；请求体只有
  model / max_tokens / system / 一条 user 消息，不带思考参数）；应答按块的 `type` 取 `text`，`stop_reason` 不是
  `end_turn`、非 200、没有 `text` 块各自显式失败。网关由本地 HTTP 替身（`test/support/http_stub.exs`）代替，
  它回放网关核实时的一次真实响应（夹具 `gateway-response.json`，来源见夹具目录的 README）；模型用量经
  `npc_model_request` 的记录读回，覆盖供应商计量、无用量、超时和取消。不验证模型写作内容。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  @moduletag :t0
  alias NpcServer.{HttpStub, Secret}
  alias NpcServer.Life.Reflection.Writer

  @fixtures Path.expand("../support/fixtures/reflection", __DIR__)

  setup_all do
    Logger.put_module_level(NpcServer.ModelUsage, :info)
    on_exit(fn -> Logger.delete_module_level(NpcServer.ModelUsage) end)
    :ok
  end

  test "sends the measured Messages request and reads the text block that follows the empty thinking block" do
    response = fixture("gateway-response.json")

    # 夹具本身的形状：第一块是空的 thinking、第二块是 text。这里按位置拆开只为取期望值，被测代码按 type 取。
    assert %{
             "stop_reason" => "end_turn",
             "usage" => usage,
             "content" => [
               %{"type" => "thinking", "thinking" => ""},
               %{"type" => "text", "text" => expected}
             ]
           } = Jason.decode!(response)

    # 系统提示词与用户消息用 S1-X2 真实发出的原文（与这份响应的请求同一份材料）。
    system = fixture("system-prompt.txt")
    user = fixture("round4-user-Q_place.txt")
    config = server(fn :post, "/v1/messages", _ -> {200, response} end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, %{text: ^expected, usage: ^usage, tokens: tokens}} =
                 Writer.write(config, system, user, %{cid: 37, operation: :reflection})

        assert %{input_tokens: 7135, output_tokens: 747} = tokens
      end)

    assert [%{"event" => "started", "request_id" => id} = started, finished] = model_events(log)

    assert %{
             "cid" => 37,
             "operation" => "reflection",
             "api" => "messages",
             "request_model" => "claude/claude-sonnet-5-5",
             "node" => logged_node
           } = started

    assert logged_node == Atom.to_string(node())

    assert %{
             "event" => "finished",
             "request_id" => ^id,
             "cid" => 37,
             "response_model" => "claude/claude-sonnet-5-5",
             "duration_ms" => duration
           } = finished

    assert is_integer(duration) and duration >= 0
    refute log =~ "test-key"
    refute log =~ config.url

    assert [%{headers: headers, body: body}] = HttpStub.requests(1)
    assert headers["x-api-key"] == "test-key"
    assert headers["anthropic-version"] == "2023-06-01"
    assert headers["content-type"] == "application/json"
    refute Map.has_key?(headers, "authorization")

    # 请求体逐键相等：不带 thinking、output_config 等任何思考参数。
    assert body == %{
             "model" => "claude/claude-sonnet-5-5",
             "max_tokens" => 2000,
             "system" => system,
             "messages" => [%{"role" => "user", "content" => user}]
           }
  end

  test "a non-200 answer fails with the status and the first 300 characters of the body" do
    error =
      Jason.encode!(%{
        "type" => "error",
        "error" => %{
          "type" => "rate_limit_error",
          "message" => String.duplicate("slow down ", 40)
        }
      })

    config = server(fn :post, _, _ -> {429, error} end)

    log =
      capture_log([level: :info], fn ->
        assert {:error, {:http_status, 429, excerpt}} = Writer.write(config, "system", "user")
        assert excerpt == String.slice(error, 0, 300)
      end)

    assert [_, %{"status" => "http_error", "status_code" => 429, "usage" => nil}] =
             model_events(log)

    refute log =~ "slow down"
  end

  test "a stop_reason other than end_turn fails with the actual value even when text is present" do
    truncated =
      fixture("gateway-response.json") |> Jason.decode!() |> Map.put("stop_reason", "max_tokens")

    config = server(fn :post, _, _ -> {200, truncated} end)

    log =
      capture_log([level: :info], fn ->
        assert {:error, {:stop_reason, "max_tokens"}} = Writer.write(config, "system", "user")
      end)

    assert [
             %{"event" => "started", "request_id" => id, "cid" => nil, "operation" => "write"},
             finished
           ] = model_events(log)

    assert %{
             "event" => "finished",
             "request_id" => ^id,
             "status" => "response",
             "usage" => %{
               "input_tokens" => 7135,
               "output_tokens" => 747,
               "cache_read_input_tokens" => 0,
               "cache_creation_input_tokens" => 7133
             }
           } = finished
  end

  test "missing usage stays unknown without rejecting a valid response" do
    response = %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "hi"}]}
    config = server(fn :post, _, _ -> {200, response} end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, %{text: "hi", usage: nil, tokens: nil}} =
                 Writer.write(config, "system", "user")
      end)

    assert [_, %{"status" => "response", "usage" => nil}] = model_events(log)
  end

  test "invalid JSON preserves the existing error and has no known usage" do
    config = server(fn :post, _, _ -> {200, "private response"} end)

    log =
      capture_log([level: :info], fn ->
        assert {:error, :invalid_json} = Writer.write(config, "system", "user")
      end)

    assert [_, %{"status" => "invalid_json", "usage" => nil}] = model_events(log)
    refute log =~ "private response"
  end

  test "a timed out request has no known usage" do
    config = %{server(fn :post, _, _ -> blocked_response() end) | timeout_ms: 250}

    log =
      capture_log([level: :info], fn ->
        assert {:error, :timeout} = Writer.write(config, "system", "user")
      end)

    assert [_] = HttpStub.requests(1)
    assert [_, %{"status" => "timeout", "usage" => nil}] = model_events(log)
  end

  test "closing a worker with a request in flight leaves only the started event" do
    config = server(fn :post, _, _ -> blocked_response() end)

    log =
      capture_log([level: :info], fn ->
        {pid, monitor} = spawn_monitor(fn -> Writer.write(config, "system", "user") end)
        assert [_] = HttpStub.requests(1)
        Process.exit(pid, :shutdown)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 1000
      end)

    assert [%{"event" => "started"}] = model_events(log)
  end

  test "an end_turn answer without any text block fails" do
    thinking_only =
      fixture("gateway-response.json")
      |> Jason.decode!()
      |> Map.update!("content", fn blocks -> Enum.reject(blocks, &(&1["type"] == "text")) end)

    assert [%{"type" => "thinking"}] = thinking_only["content"]
    config = server(fn :post, _, _ -> {200, thinking_only} end)

    assert {:error, :no_text} = Writer.write(config, "system", "user")
  end

  # —— `:openai` 入口（chat completions）。夹具 `deepseek-chat-response.json` 是下面 live 冒烟留下的真实 DeepSeek 回执。 ——

  test "openai: sends a chat request with a bearer key and reads the content, not the reasoning" do
    response = fixture("deepseek-chat-response.json")

    assert %{
             "choices" => [
               %{
                 "finish_reason" => "stop",
                 "message" => %{"content" => expected, "reasoning_content" => reasoning}
               }
             ],
             "usage" => usage
           } = Jason.decode!(response)

    assert reasoning != "" and reasoning != expected

    system = fixture("system-prompt.txt")
    user = fixture("round4-user-Q_place.txt")
    config = chat_server(fn :post, "/chat/completions", _ -> {200, response} end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, %{text: ^expected, usage: ^usage, tokens: tokens}} =
                 Writer.write(config, system, user, %{cid: 37, operation: :reflection})

        assert %{input_tokens: 3931, output_tokens: 1042, cache_read_input_tokens: 0} = tokens
      end)

    assert [
             %{"event" => "started", "api" => "openai", "request_model" => "deepseek-flash"},
             %{
               "event" => "finished",
               "status" => "response",
               "response_model" => "deepseek-flash"
             }
           ] = model_events(log, "deepseek-flash")

    refute log =~ "deepseek-test-key"

    assert [%{headers: headers, body: body}] = HttpStub.requests(1)
    assert headers["authorization"] == "Bearer deepseek-test-key"
    refute Map.has_key?(headers, "x-api-key")

    assert body == %{
             "model" => "deepseek-flash",
             "max_tokens" => 8192,
             "reasoning_effort" => "medium",
             "messages" => [
               %{"role" => "system", "content" => system},
               %{"role" => "user", "content" => user}
             ]
           }
  end

  test "openai: a finish_reason other than stop fails with the actual value, usage still recorded" do
    truncated =
      fixture("deepseek-chat-response.json")
      |> Jason.decode!()
      |> put_in(["choices", Access.at(0), "finish_reason"], "length")

    config = chat_server(fn :post, _, _ -> {200, truncated} end)

    log =
      capture_log([level: :info], fn ->
        assert {:error, {:finish_reason, "length"}} = Writer.write(config, "system", "user")
      end)

    assert [_, %{"status" => "response", "usage" => %{"output_tokens" => 1042}}] =
             model_events(log, "deepseek-flash")
  end

  test "openai: a stop answer with empty content fails as no_text" do
    empty =
      fixture("deepseek-chat-response.json")
      |> Jason.decode!()
      |> put_in(["choices", Access.at(0), "message", "content"], "")

    config = chat_server(fn :post, _, _ -> {200, empty} end)
    assert {:error, :no_text} = Writer.write(config, "system", "user")
  end

  test "openai: a JSON answer without choices is not a chat response" do
    config = chat_server(fn :post, _, _ -> {200, %{"object" => "error"}} end)
    assert {:error, :invalid_response} = Writer.write(config, "system", "user")
  end

  # 真实 OpenAI 兼容写作端点（2026-11-18 起部署统一用 DeepSeek）的一次冒烟。只在显式 `--only live_reflect_openai`
  # 且环境里写了 `NPC_REFLECT_API=openai` 与 `NPC_REFLECT_URL/_KEY/_MODEL` 时跑。
  # Writer 照常把请求发给本机替身；替身把产品构造的请求体原样转发到真实端点（鉴权只在这里加），回执原样交回 Writer。
  # 这样一次真实请求同时验证：产品请求体被供应商接受、`finish_reason` 是 `stop`（不是 `length` 截断）、正文按产品读法取得到。
  # 给了 `NPC_LIVE_CAPTURE` 时把回执（解码后重新编码的 JSON，不含凭据）写到该路径，作 chat 形状单元用例的夹具来源。
  # 材料用 S1-X2 真实发过的系统提示词与第 4 轮用户消息（与 `gateway-response.json` 同一份）。
  # 真实模型用例挂 `:live_llm`（test_helper 缺省排除）。
  @tag :live_llm
  @tag :live_reflect_openai
  @tag timeout: 180_000
  test "the real OpenAI-compatible writer endpoint writes one journal entry through the product request" do
    if System.get_env("NPC_REFLECT_API") != "openai" do
      flunk("live: 需要 NPC_REFLECT_API=openai 与 NPC_REFLECT_URL / _KEY / _MODEL")
    end

    upstream = %{
      url: System.fetch_env!("NPC_REFLECT_URL"),
      key: Secret.wrap(System.fetch_env!("NPC_REFLECT_KEY")),
      timeout_ms: 150_000
    }

    capture = System.get_env("NPC_LIVE_CAPTURE")

    forward = fn :post, _path, body ->
      case NpcServer.Http.request(upstream, body) do
        {:ok, response} ->
          if capture, do: File.write!(capture, Jason.encode!(response, pretty: true))
          {200, response}

        {:error, {status, excerpt}} when is_integer(status) ->
          {status, excerpt}
      end
    end

    config = %{
      api: :openai,
      url: HttpStub.start(forward) <> "/chat/completions",
      key: Secret.wrap("local-forwarder"),
      model: System.fetch_env!("NPC_REFLECT_MODEL"),
      reasoning_effort: System.get_env("NPC_REFLECT_EFFORT", "medium"),
      timeout_ms: 160_000
    }

    started = System.monotonic_time(:millisecond)

    result =
      Writer.write(config, fixture("system-prompt.txt"), fixture("round4-user-Q_place.txt"), %{
        cid: nil,
        operation: :live_smoke
      })

    elapsed = System.monotonic_time(:millisecond) - started
    assert [%{body: body}] = HttpStub.requests(1)

    IO.puts(
      "live_reflect openai model=#{config.model} effort=#{config.reasoning_effort} " <>
        "elapsed_ms=#{elapsed} request_keys=#{inspect(Map.keys(body) |> Enum.sort())} " <>
        "result=#{inspect(result, limit: 6, printable_limit: 160)}"
    )

    assert {:ok, %{text: text, tokens: %{input_tokens: _, output_tokens: _}}} = result
    assert String.length(text) > 40

    # Finch 决策稿 T-4：转发到真实端点的那一笔没标车道（后台），`https` 走后台车道的 HTTP/2 实例；
    # 该实例只接受 ALPN 协商出 h2 的连接，所以请求成功且池落在这里，即协商为 HTTP/2。
    assert {:ok, _} =
             Finch.find_pool(NpcServer.Http.BackgroundHttp2, Finch.Pool.new(upstream.url))
  end

  defp server(handler),
    do: %{
      url: HttpStub.start(handler) <> "/v1/messages",
      key: Secret.wrap("test-key"),
      model: "claude/claude-sonnet-5-5",
      timeout_ms: 1000
    }

  defp chat_server(handler),
    do: %{
      api: :openai,
      url: HttpStub.start(handler) <> "/chat/completions",
      key: Secret.wrap("deepseek-test-key"),
      model: "deepseek-flash",
      reasoning_effort: "medium",
      timeout_ms: 1000
    }

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # 回执一直等到测试替身退出，避免真实响应和超时或取消抢先。
  defp blocked_response do
    receive do
      :respond -> {200, %{}}
    end
  end

  defp model_events(log, model \\ "claude/claude-sonnet-5-5") do
    for [_, json] <- Regex.scan(~r/npc_model_request (\{[^\n]+\})/, log),
        event = Jason.decode!(json),
        event["request_model"] == model,
        do: event
  end
end
