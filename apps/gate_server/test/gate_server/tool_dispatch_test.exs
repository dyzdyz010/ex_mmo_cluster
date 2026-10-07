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

  # 能力库 I1 只合并 in_scene 子句；未入场时各 kind 的拒绝帧逐字节保持原样（设计稿 F24）。期望按线布局手写：
  # 0x68 = rid u64、seq u32、scene u64、result 2（rejected）、ref u64、authoritative u16、reason u16 长度 + 文本；
  # 通用错误 = 0x80、packet u64 = 0、status 1。
  test "outside a scene each world intent keeps its original rejection frame" do
    state = %{
      status: :connected,
      voxim_overlay: true,
      cid: 5,
      sink: GateServer.Session.Sink.quic(self(), :session)
    }

    head = %{request_id: 1, client_intent_seq: 2, logical_scene_id: 3}

    rejected =
      <<0x68, 1::64, 2::32, 3::64, 2, 0::64, 0::16, 14::16>> <> ":invalid_state"

    for {kind, fields, frame} <- [
          {:voxel_production_intent, %{action: 1, coord: {0, 0, 0}, tool_id: 1, material: 11},
           rejected},
          {:voxel_production_intent, %{action: 0, coord: {0, 0, 0}, tool_id: 1, material: 0},
           rejected},
          {:voxel_attachment_intent, %{action: 0}, rejected},
          {:voxel_tool_intent, %{action: 1, granularity: 0}, rejected},
          {:voxel_prefab_place_v1, %{}, <<0x80, 0::64, 1>>},
          {:voxel_prefab_remove_v1, %{}, <<0x80, 0::64, 1>>},
          {:voxel_prefab_replace_v1, %{}, <<0x80, 0::64, 1>>},
          {:voxel_prefab_publish_v1, %{}, <<0x80, 0::64, 1>>}
        ] do
      assert {:ok, ^state} =
               GateServer.Session.Dispatch.handle({kind, Map.merge(head, fields)}, state)

      assert_receive {:mmo_voxel_bytes, :session, ^frame}
    end

    refute_receive {:mmo_voxel_bytes, _, _}, 0
  end
end
