defmodule GateServer.ToolDispatchTest do
  @moduledoc "Test-only: receipt transport seam, with an explicitly completed owner result. Does not test hit authority."
  use ExUnit.Case, async: true
  alias MmoContracts.Session

  defmodule CompletedOwner do
    use GenServer
    def start_link(receipt), do: GenServer.start_link(__MODULE__, receipt)
    def init(receipt), do: {:ok, receipt}

    def handle_call({:authorize_tool, _, _, _}, _, receipt),
      do: {:reply, {:done, {:body, receipt}}, receipt}
  end

  test "tool receipt uses control stream accepted by real client" do
    identity = %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3}

    receipt = %{
      source_id: 5,
      source_session: 1,
      source_life: 7,
      action_seq: 8,
      target_id: 9,
      target_life: 10,
      part: :torso,
      body: %{life: 80, recoverable: 20}
    }

    owner = start_supervised!({CompletedOwner, receipt})

    state = %{
      status: :in_scene,
      voxim_overlay: true,
      identity: identity,
      player: owner,
      world_ref: :unused_completed_result,
      sink: GateServer.Session.Sink.quic(self(), make_ref())
    }

    request = %{action: 1, granularity: 5, request_id: 4}

    assert {:ok, ^state} =
             GateServer.Session.Dispatch.handle({:voxel_tool_intent, request}, state)

    assert_receive {:mmo_reliable, ^identity, 1,
                    %Session.ToolState{request_id: 4, target_id: 9, life: 80}}

    refute_receive {:mmo_voxel_bytes, _, _}
  end
end
