Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule GateServer.VoximPrefabPublishDispatchTest do
  @moduledoc "只测试：D3 0x71 冻结帧经正式解码与 Dispatch 进入真实 World，名称随发布持久化，非法名称以 0x68 拒绝。"
  use ExUnit.Case, async: false
  alias GateServer.Session.{Dispatch, Sink}
  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Actor}

  @vxpd "VXPD" <> <<3::32-little, 0::32, 0::32, 0::32, 1::32-little, 0::96, 11::16-little>>
  @header <<0x71, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 38>>

  setup do
    root = Path.join(System.tmp_dir!(), "d3_publish_dispatch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    world =
      start_supervised!(
        {World,
         source: Source,
         root: root,
         observer: self(),
         name: nil,
         property_catalog_path: VoxelRegion.TestSupport.catalog(),
         prefab_catalog_path: nil,
         production_materials: [11, 19]}
      )

    actor = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {1.0625, 1.0625, 0.0625}, tick_us: 16_667}
    player = start_supervised!({Actor, actor})

    state = %{
      status: :in_scene,
      voxim_overlay: true,
      player: player,
      identity: actor.identity,
      world_ref: world,
      sink: Sink.quic(self(), :session)
    }

    %{world: world, state: state}
  end

  defp publish(state, name_bytes) do
    {:ok, message} = Codec.decode(@header <> @vxpd <> name_bytes)
    assert {:ok, ^state} = Dispatch.handle(message, state)
    assert_receive {:mmo_voxel_bytes, :session, reply}
    reply
  end

  test "named publish is accepted and listed; a control character is rejected as :invalid_name", c do
    # 名称 "石\n屋"：7 字节，含 LF。
    assert publish(c.state, <<0, 7, 0xE7, 0x9F, 0xB3, 0x0A, 0xE5, 0xB1, 0x8B>>) ==
             <<0x68, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 2, 0, 0, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 13>> <> ":invalid_name"

    assert World.published_prefabs(c.world) == []

    assert publish(c.state, <<0, 6, 0xE7, 0x9F, 0xB3, 0xE5, 0xB1, 0x8B>>) ==
             <<0x68, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 2>> <> "ok"

    assert World.published_prefabs(c.world) == [{1001, "石屋", @vxpd}]
  end
end
