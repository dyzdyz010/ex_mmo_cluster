Code.require_file("../support/http_stub.exs", __DIR__)

defmodule NpcServer.NpcSpeakTest do
  @moduledoc "只测试：真实说话技能、寻路技能及写作 HTTP 适配器。Body 的逐步结果和远端写作由替身提供。"
  use ExUnit.Case, async: true
  @moduletag :t0
  alias NpcServer.{HttpStub, Skills}
  alias NpcServer.Skills.Speak

  # 写作替身在回环上立即应答，本用例不验证超时。但它是 async 用例：全量运行开头与几十个用例同跑，写作又常是本 VM
  # 第一个交互车道请求（新端口要建池、首次加载 Finch / Mint），从到达到替身收到请求可以超过 1 秒。
  # 所以只等真实事件（替身收到请求、Body 收到 say），上限取写作这一步按 `NpcServer.Http` 超时契约的最坏时长：
  # 交互车道取连接 2 s + 建连 2 s + 2 × endpoint 的 `timeout_ms`。到点仍等不到，就是产品没守住自己的截止；
  # 写作若显式失败，任务的应答会出现在断言失败时打印的邮箱里。
  @timeout_ms 5_000
  @write_deadline_ms 2_000 + 2_000 + 2 * @timeout_ms

  @tag :model_usage
  test "drafts once after reaching the selected person and preserves an unknown say result" do
    assert Code.ensure_loaded?(Speak), "说话技能必须可执行"

    %{"usage" => usage} =
      "../support/fixtures/reflection/gateway-response.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    url =
      HttpStub.start(fn :post, "/v1/messages", _ ->
        {200,
         %{
           "stop_reason" => "end_turn",
           "content" => [%{"type" => "text", "text" => "阿乔，早上好。"}],
           "usage" => usage
         }}
      end)

    context = %{
      body: self(),
      call_id: 7,
      actor: %{cid: 11},
      profile: %{
        skills: %{speak: %{module: Speak}},
        reflect: %{
          url: url <> "/v1/messages",
          key: NpcServer.Secret.wrap("test-key"),
          model: "test",
          timeout_ms: @timeout_ms
        }
      },
      observation: %{self: %{position: {0.0, 65.0, 0.0}}},
      movement_profile: %{half_height: 0.9},
      mind_snapshot: "I am looking after the plaza."
    }

    args = %{
      "entity_id" => 21,
      "entity_epoch" => 3,
      "name" => "阿乔"
    }

    task = Task.async(fn -> Skills.run(context, %{skill: :speak, args: args}) end)

    assert_receive {:"$gen_cast",
                    {:command,
                     %{
                       id: {:skill, 7, travel_step},
                       verb: :get_target_status,
                       target: %{entity_id: 21, entity_epoch: 3}
                     }}},
                   2000

    refute_received {:http_request, _}

    send(task.pid, {
      :outcome,
      %{id: travel_step, status: :done, data: %{valid: true, position: {1.0, 65.0, 0.0}}}
    })

    assert_receive {:http_request,
                    %{body: %{"messages" => [%{"role" => "user", "content" => prompt}]} = body}},
                   @write_deadline_ms

    assert prompt =~ "I am looking after the plaza."
    assert prompt =~ "阿乔"

    assert body["system"] =~
             "Claim to have personally seen an event only when the state explicitly records that observation."

    assert body["system"] =~
             "If you address a specific incident and the motive is unknown, ask about it in character."

    refute Map.has_key?(body, "tools")

    assert_receive {:"$gen_cast",
                    {:command,
                     %{
                       id: {:skill, 7, say_step},
                       verb: :say,
                       text: "阿乔，早上好。",
                       target_id: 21,
                       target_epoch: 3,
                       conversation_id: 0
                     }}},
                   @write_deadline_ms

    refute say_step == travel_step
    send(task.pid, {:outcome, %{id: say_step, status: :rejected, reason: :delivery_unknown}})

    assert {:error, :delivery_unknown,
            %{request_count: 1, input_tokens: 7135, output_tokens: 747}} =
             Task.await(task, 2000)

    refute_received {:http_request, _}
    refute_received {:"$gen_cast", {:command, _}}
  end
end
