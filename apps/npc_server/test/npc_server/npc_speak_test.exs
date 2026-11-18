Code.require_file("../support/http_stub.exs", __DIR__)

defmodule NpcServer.NpcSpeakTest do
  @moduledoc "只测试：真实说话技能、寻路技能及写作 HTTP 适配器。Body 的逐步结果和远端写作由替身提供。"
  use ExUnit.Case, async: true
  @moduletag :t0
  alias NpcServer.{HttpStub, Skills}
  alias NpcServer.Skills.Speak

  test "drafts once after reaching the selected person and preserves an unknown say result" do
    assert Code.ensure_loaded?(Speak), "说话技能必须可执行"
    {:ok, _} = Application.ensure_all_started(:inets)

    url =
      HttpStub.start(fn :post, "/v1/messages", _ ->
        {200,
         %{
           "stop_reason" => "end_turn",
           "content" => [%{"type" => "text", "text" => "阿乔，早上好。"}],
           "usage" => %{"input_tokens" => 17, "output_tokens" => 5}
         }}
      end)

    context = %{
      body: self(),
      call_id: 7,
      profile: %{
        skills: %{speak: %{module: Speak}},
        reflect: %{url: url <> "/v1/messages", key: "test-key", model: "test", timeout_ms: 1000}
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

    assert [%{body: %{"messages" => [%{"role" => "user", "content" => prompt}]} = body}] =
             HttpStub.requests(1)

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
                   2000

    refute say_step == travel_step
    send(task.pid, {:outcome, %{id: say_step, status: :rejected, reason: :delivery_unknown}})

    assert {:error, :delivery_unknown, %{request_count: 1, input_tokens: 17, output_tokens: 5}} =
             Task.await(task, 2000)

    refute_received {:http_request, _}
    refute_received {:"$gen_cast", {:command, _}}
  end
end
