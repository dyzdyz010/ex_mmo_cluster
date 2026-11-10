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

  # 徒手分选（Items 增量 1）：action 6 交角色 owner 的读条入口，回执等读条结束在独立进程里发；action 7 同步取消。
  # 0x68 = rid u64、seq u32、scene u64、result（0 accepted / 2 rejected）、ref u64、authoritative u16、reason u16 长度 + 文本。
  # 本进程扮 Player（角色 owner 读条由 scene_server beacon_travel_test 覆盖）。
  defp sort_state(c, player),
    do: %{status: :in_scene, voxim_overlay: true, cid: 1001, player: player, identity: :session, world_ref: c.w,
      sink: Sink.quic(self(), :session)}

  defp sort_request(rid, action),
    do: %{request_id: rid, client_intent_seq: rid, logical_scene_id: 1, action: action, coord: {0, 0, 0}, tool_id: 24, material: 89}

  test "分选 action 6：放行回 accepted(seq) 后补发余额；拒绝回 rejected 原因、不补发", c do
    test = self()

    player =
      spawn_link(fn ->
        for result <- [{:ok, 5}, {:error, :cast_cancelled}] do
          receive do
            {:"$gen_cast", {:sort, :session, request, {waiter, tag}}} ->
              send(test, {:sort_seen, request.request_id})
              send(waiter, {tag, result})
          end
        end
      end)

    assert {:ok, _} = Dispatch.handle({:voxel_production_intent, sort_request(7, 6)}, sort_state(c, player))
    assert_receive {:sort_seen, 7}
    assert_receive {:mmo_voxel_bytes, :session, <<0x68, 7::64, 7::32, 1::64, 0, 5::64, 0::16, 2::16, "ok">>}, 1_000
    assert_receive {:mmo_voxel_bytes, :session, <<0x81, 7::64, _::binary>>}, 1_000
    assert_receive {:mmo_voxel_bytes, :session, <<0x81, 7::64, _::binary>>}, 1_000

    assert {:ok, _} = Dispatch.handle({:voxel_production_intent, sort_request(8, 6)}, sort_state(c, player))
    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 8::64, 8::32, 1::64, 2, 0::64, 0::16, 15::16, ":cast_cancelled">>}, 1_000
    refute_receive {:mmo_voxel_bytes, :session, _}, 100
  end

  test "取消分选 action 7：打断回 accepted(0)，没有可取消的分选回 rejected already_released", c do
    player =
      spawn_link(fn ->
        for reply <- [:ok, {:error, :already_released}] do
          receive do
            {:"$gen_call", from, {:cancel_sort, :session}} -> GenServer.reply(from, reply)
          end
        end
      end)

    assert {:ok, _} = Dispatch.handle({:voxel_production_intent, sort_request(9, 7)}, sort_state(c, player))
    assert_receive {:mmo_voxel_bytes, :session, <<0x68, 9::64, 9::32, 1::64, 0, 0::64, 0::16, 2::16, "ok">>}, 1_000
    assert {:ok, _} = Dispatch.handle({:voxel_production_intent, sort_request(10, 7)}, sort_state(c, player))
    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 10::64, 10::32, 1::64, 2, 0::64, 0::16, 17::16, ":already_released">>}, 1_000
    refute_receive {:mmo_voxel_bytes, :session, _}, 100
  end

  # 信标出发与分选共用 Dispatch.await_result/2：读条结果在独立进程里等，Player 先退出按 invalid_session 回。
  # 信标放行只回 accepted(0)（到达由 Relocate 体现），不回余额。
  test "信标出发：放行回 accepted(0)；拒绝回 rejected 原因", c do
    player =
      spawn_link(fn ->
        for result <- [{:ok, 0}, {:error, :beacon_moved}] do
          receive do
            {:"$gen_cast", {:beacon, :session, _request, {waiter, tag}}} -> send(waiter, {tag, result})
          end
        end
      end)

    travel = fn rid -> {:voxel_beacon_travel, %{request_id: rid, client_intent_seq: rid, logical_scene_id: 1, from: "a", to: "b"}} end

    assert {:ok, _} = Dispatch.handle(travel.(11), sort_state(c, player))
    assert_receive {:mmo_voxel_bytes, :session, <<0x68, 11::64, 11::32, 1::64, 0, 0::64, 0::16, 2::16, "ok">>}, 1_000
    assert {:ok, _} = Dispatch.handle(travel.(12), sort_state(c, player))
    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 12::64, 12::32, 1::64, 2, 0::64, 0::16, 13::16, ":beacon_moved">>}, 1_000
    refute_receive {:mmo_voxel_bytes, :session, _}, 100
  end

  test "读条中 Player 退出：信标与分选都回 rejected invalid_session", c do
    exiting = fn tag ->
      spawn(fn ->
        receive do
          {:"$gen_cast", {^tag, :session, _request, _from}} -> :ok
        end
      end)
    end

    beacon = %{request_id: 13, client_intent_seq: 13, logical_scene_id: 1, from: "a", to: "b"}
    assert {:ok, _} = Dispatch.handle({:voxel_beacon_travel, beacon}, sort_state(c, exiting.(:beacon)))
    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 13::64, 13::32, 1::64, 2, 0::64, 0::16, 16::16, ":invalid_session">>}, 1_000

    assert {:ok, _} = Dispatch.handle({:voxel_production_intent, sort_request(14, 6)}, sort_state(c, exiting.(:sort)))
    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x68, 14::64, 14::32, 1::64, 2, 0::64, 0::16, 16::16, ":invalid_session">>}, 1_000
    refute_receive {:mmo_voxel_bytes, :session, _}, 100
  end
end
