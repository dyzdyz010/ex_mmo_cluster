defmodule GateServer.VoximProductionDispatchTest do
  @moduledoc "只测试：B2 会话派发与 Ready 前按鉴权身份查询库存。"
  use ExUnit.Case, async: false
  alias GateServer.Session.{Dispatch, Sink}
  alias VoxelRegion.World

  defmodule Source do
    # 空世界夹具只提供启动元数据；本用例不需要读取或编辑几何。
    def open(opts), do: {:ok, Keyword.fetch!(opts, :root)}
    def content_version(_), do: 123
    def world_dir(root), do: root
  end

  setup do
    root = Path.join(System.tmp_dir!(), "b2_dispatch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    world =
      start_supervised!(
        {World,
         source: Source,
         root: root,
         name: nil,
         property_catalog_path: nil,
         prefab_catalog_path: nil,
         production_materials: [19, 11]}
      )

    %{w: world}
  end

  @tag :b2
  test "B2 balance query uses authenticated cid before movement Ready",
       c do
    state = %{
      status: :in_scene,
      voxim_overlay: true,
      cid: 1001,
      world_ref: c.w,
      sink: Sink.quic(self(), :session)
    }

    request = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 0,
      coord: {0, 0, 0},
      tool_id: 1
    }

    assert {:ok, ^state} = Dispatch.handle({:voxel_production_intent, request}, state)
    assert_receive {:mmo_voxel_bytes, :session, <<0x81, 1::64, 0::64, 19::16, 0::64, 512::32>>}
    assert_receive {:mmo_voxel_bytes, :session, <<0x81, 1::64, 0::64, 11::16, 0::64, 512::32>>}

    assert World.seq(c.w) == 0
    assert Enum.all?(World.material_balances(c.w, 1001), &(&1.balance == 0))
  end

  # 余额是回执之后的另一次 World 查询；回执不等它，先到客户端。
  @tag :b2
  test "B2 build result reaches the client before the balance refresh", c do
    player =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, {:tool_context, :session}} ->
            GenServer.reply(from, {:ok, %{cid: 1001}})
        end
      end)

    state = %{
      status: :in_scene,
      voxim_overlay: true,
      cid: 1001,
      player: player,
      identity: :session,
      world_ref: c.w,
      sink: Sink.quic(self(), :session)
    }

    request = %{
      request_id: 2,
      client_intent_seq: 2,
      logical_scene_id: 1,
      action: 1,
      coord: :outside_world,
      tool_id: 1,
      material: 19
    }

    assert {:ok, _} = Dispatch.handle({:voxel_production_intent, request}, state)

    frames =
      for _ <- 1..3,
          do:
            (receive do
               {:mmo_voxel_bytes, :session, bytes} -> bytes
             after
               1_000 -> nil
             end)

    assert [<<0x68, _::binary>>, <<0x81, 2::64, _::binary>>, <<0x81, 2::64, _::binary>>] = frames
  end
end
