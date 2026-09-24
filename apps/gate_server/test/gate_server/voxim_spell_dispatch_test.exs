Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule GateServer.VoximSpellDispatchTest do
  @moduledoc """
  只测试：魔法增量 1 的 Gate 胶合——0x82 经正式解码与 Dispatch 进入真实 World；报价只回 0x83，
  施放（含走火）先回 0x83 再回 0x68 accepted，拒绝回 0x68 rejected；QUIC 接纳 0x76 后的施法者状态请求回 0x83（request_id 0）。
  World 用 Test-only 魔法目录 8f418a41… 与材料目录 b1aca503…；施法者能量 0（新角色），走火扣 0。
  """
  use ExUnit.Case, async: false
  alias GateServer.Session.{Dispatch, Sink}
  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Actor}

  @fixtures Path.expand("../../../voxel_region/test/fixtures", __DIR__)
  @magic "8f418a4136db1571d26ae6f54ac02268c45218e0738b74af671206876888f136"

  setup do
    root = Path.join(System.tmp_dir!(), "magic_dispatch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    world =
      start_supervised!(
        {World,
         source: Source,
         root: root,
         observer: self(),
         name: nil,
         property_catalog_path:
           Path.join([@fixtures, "combustion", "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec.json"]),
         thermal_environment_path: Path.join([@fixtures, "combustion", "environment-radiation.json"]),
         magic_catalog_path: Path.join([@fixtures, "magic", @magic <> ".json"]),
         prefab_catalog_path: nil}
      )

    # 地面石 (0,0,0)、叶 (0,2,3)；脚 (0.5,1,0.5)、眼 (0.5,2.5,0.5)，叶在正 z 方向 3 m。
    {:ok, _} = World.apply_edits(world, [{{0, 0, 0}, 11}, {{0, 2, 3}, 28}])

    actor = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5}, feet: {0.5, 1.0, 0.5}, tick_us: 16_667}
    player = start_supervised!({Actor, actor})

    state = %{
      status: :in_scene,
      voxim_overlay: true,
      player: player,
      identity: actor.identity,
      cid: 1001,
      world_ref: world,
      received_us: 1_000_000,
      clock_node: node(),
      sink: Sink.quic(self(), :session)
    }

    %{world: world, state: state}
  end

  # 0x82：rid 7、seq 8、scene 1、目标 = 叶宏格 (0,2,3) 的角微格 {0,16,24}、incarnation 1（作者编辑后的纪元）、
  # 方向 (0,0,1)、程序 = 契约预设 ignite_near。
  defp spell(action, digest) do
    program = ~s({"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":"act.heat","args":{"energy_j":400000,"power_w":50000}}]})

    <<0x82, 7::64, 8::32, 1::64, action, digest::binary-size(32), 0.0::float-64, 0.0::float-64, 1.0::float-64,
      0::signed-64, 16::signed-64, 24::signed-64, 1::64, 0::64, 0::32, 28::16, 0, byte_size(program)::16,
      program::binary>>
  end

  defp dispatch(state, bytes) do
    {:ok, message} = Codec.decode(bytes)
    assert {:ok, ^state} = Dispatch.handle(message, state)
  end

  test "报价回 0x83（报价 403 313.0047 J、S 1）；施放走火先 0x83 再 0x68 accepted misfire_energy；目录过期 0x68 rejected", c do
    digest = Base.decode16!(@magic, case: :lower)
    dispatch(c.state, spell(0, digest))
    # 报价：0.4 MJ + 2000 × 1.4^1.5 = 403 313.0047 J；能量 0、容量 5 MJ、相干度 4、支出 0。
    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 7::64, 1::64, +0.0::float-64, 5.0e6::float-64, 4.0::float-64, quote::float-64, 1.0::float-64,
                      +0.0::float-64>>}
    assert_in_delta quote, 403_313.0047, 1.0e-4
    refute_receive {:mmo_voxel_bytes, :session, _}, 50
    assert World.seq(c.world) == 1

    dispatch(c.state, spell(1, digest))
    # 余额 0 < 403 313 J：走火扣 min(总支出, 0) = 0；已提交事务 seq 2。
    assert_receive {:mmo_voxel_bytes, :session, <<0x83, 7::64, 2::64, _::binary>>}
    assert_receive {:mmo_voxel_bytes, :session, <<0x68, 7::64, 8::32, 1::64, 0, 2::64, 0::16, 14::16, "misfire_energy">>}
    assert World.seq(c.world) == 2

    dispatch(c.state, spell(1, <<0::256>>))
    assert_receive {:mmo_voxel_bytes, :session, <<0x68, 7::64, 8::32, 1::64, 2, 0::64, 0::16, 20::16, ":stale_magic_catalog">>}
    assert World.seq(c.world) == 2
  end

  test "QUIC 接纳 0x76 后的施法者状态请求回 0x83（request_id 0）", c do
    assert {:ok, _} = Dispatch.handle({:voxel_caster_state_request, %{request_id: 0, logical_scene_id: 1}}, c.state)
    assert_receive {:mmo_voxel_bytes, :session,
                    <<0x83, 0::64, 1::64, +0.0::float-64, 5.0e6::float-64, 4.0::float-64, +0.0::float-64, +0.0::float-64,
                      +0.0::float-64>>}
  end
end
