Code.require_file("../support/http_stub.exs", __DIR__)

defmodule NpcServer.NpcReflectionWriterTest do
  @moduledoc """
  只测试：反思写日记的模型客户端（`NpcServer.Life.Reflection.Writer`）的 HTTP 信任边界。

  契约：发出的请求同离线测量 S1-X2 实际发过的条件（`x-api-key`、`anthropic-version`、JSON；请求体只有
  model / max_tokens / system / 一条 user 消息，不带思考参数）；应答按块的 `type` 取 `text`，`stop_reason` 不是
  `end_turn`、非 200、没有 `text` 块各自显式失败。网关由本地 HTTP 替身（`test/support/http_stub.exs`）代替，
  它回放网关核实时的一次真实响应（夹具 `gateway-response.json`，来源见夹具目录的 README）；
  不验证模型写得好不好，也不覆盖超时与连接错误（那两条原样来自 `NpcServer.Http` 与 `:httpc`）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias NpcServer.HttpStub
  alias NpcServer.Life.Reflection.Writer

  @fixtures Path.expand("../support/fixtures/reflection", __DIR__)

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
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

    assert {:ok, %{text: ^expected, usage: ^usage}} = Writer.write(config, system, user)

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

    assert {:error, {:http_status, 429, excerpt}} = Writer.write(config, "system", "user")
    assert excerpt == String.slice(error, 0, 300)
  end

  test "a stop_reason other than end_turn fails with the actual value even when text is present" do
    truncated =
      fixture("gateway-response.json") |> Jason.decode!() |> Map.put("stop_reason", "max_tokens")

    config = server(fn :post, _, _ -> {200, truncated} end)

    assert {:error, {:stop_reason, "max_tokens"}} = Writer.write(config, "system", "user")
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

  defp server(handler),
    do: %{
      url: HttpStub.start(handler) <> "/v1/messages",
      key: "test-key",
      model: "claude/claude-sonnet-5-5",
      timeout_ms: 1000
    }

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))
end
