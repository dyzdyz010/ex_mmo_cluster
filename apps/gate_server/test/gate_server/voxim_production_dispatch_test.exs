defmodule GateServer.VoximProductionDispatchTest do
  @moduledoc "只测试：B2 会话派发、Ready 前库存查询与作者权限边界。"
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
  test "B2 balance query uses authenticated cid before movement Ready; author bypasses stay closed",
       c do
    state = %{
      status: :in_scene,
      voxim_overlay: true,
      cid: 1001,
      world_ref: c.w,
      sink: Sink.quic(self(), :session),
      builder: false
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

    for kind <- [
          :voxel_edit_intent,
          :voxel_batch_edit_intent,
          :voxel_prefab_place_v1,
          :voxel_prefab_remove_v1,
          :voxel_prefab_replace_v1
        ] do
      assert {:ok, ^state} = Dispatch.handle({kind, request}, state)
      assert_receive {:mmo_voxel_bytes, :session, bytes}
      assert :binary.match(bytes, "builder_permission_required") != :nomatch
    end

    assert World.seq(c.w) == 0
    assert Enum.all?(World.material_balances(c.w, 1001), &(&1.balance == 0))
  end
end
