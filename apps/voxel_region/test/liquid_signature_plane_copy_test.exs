defmodule VoxelRegion.LiquidSignaturePlaneCopyTest do
  @moduledoc "只测试：合法材料平面直接参与私有指纹，不先复制到整tuple的ETF中。"
  use ExUnit.Case, async: false
  alias VoxelRegion.World.{Cache, Liquids}
  alias MmoContracts.Voxel.Payload

  test "干区指纹不序列化整段材料平面，仍为固定32字节且内容变化失效" do
    cells = :binary.copy(<<0>>, 66 * 66 * 66 * 2)
    payload = %Payload{level: 0, region: {0, 0, 0}, cells: cells}
    state = %{region_bases: %{{0, {0, 0, 0}} => payload}, overlay_regions: %{},
      overlay: %{}, decoded: %{}, cache: Cache.new(0), snapshots: MapSet.new([{0, {0, 0, 0}}]),
      liquid_bounds: {{-1, -1, -1}, {65, 65, 65}}, liquid_units: %{}, liquid_adopted: %{}}
    {checked, copies} = count_plane_serialization(fn -> Liquids.adopt_liquid_sources(state, {0, 0, 0}) end)
    signature = checked.liquid_adopted[{0, 0, 0}]
    assert byte_size(signature) == 32
    assert :binary.referenced_byte_size(signature) == 32
    assert checked.liquid_units == %{}
    assert copies == 0
    assert Liquids.adopt_liquid_sources(checked, {0, 0, 0}).liquid_adopted == checked.liquid_adopted
    changed = %{checked | region_bases: %{{0, {0, 0, 0}} => %{payload | cells: :binary.copy(<<11, 0>>, 66 * 66 * 66)}}}
    refute Liquids.adopt_liquid_sources(changed, {0, 0, 0}).liquid_adopted[{0, 0, 0}] == signature
  end

  defp count_plane_serialization(action) do
    mfa = {:erlang, :term_to_binary, 2}
    assert {:module, :erlang} = Code.ensure_loaded(:erlang)
    parent = self()
    {worker, monitor} = spawn_monitor(fn ->
      receive do
        :run ->
          send(parent, {:result, self(), action.()})
          receive do: (:stop -> :ok)
      end
    end)
    sessions = :trace.session_info(:all)
    session = :trace.session_create(:liquid_signature_plane_copy, self(), [])
    try do
      assert :trace.function(session, mfa, [{[{:"$1", :_}, :_], [{:is_binary, :"$1"}], []}], [:local]) == 1
      assert :trace.process(session, worker, true, [:call, :arity]) == 1
      send(worker, :run)
      result = receive do
        {:result, ^worker, result} -> result
      after
        5_000 -> flunk("液体指纹投影没有完成")
      end
      marker = :trace.delivered(session, worker)
      {result, drain(worker, mfa, marker, 0)}
    after
      :trace.process(session, worker, false, [:call, :arity])
      assert :trace.function(session, mfa, false, [:local]) == 1
      assert :trace.info(session, worker, :flags) == {:flags, []}
      assert :trace.info(session, mfa, :traced) == {:traced, false}
      marker = :trace.delivered(session, worker)
      assert drain(worker, mfa, marker, 0) == 0
      assert :trace.session_destroy(session)
      assert :trace.session_info(worker) == []
      assert :trace.session_info(:all) == sessions
      send(worker, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    end
  end

  defp drain(worker, mfa, marker, calls) do
    receive do
      {:trace, ^worker, :call, ^mfa} -> drain(worker, mfa, marker, calls + 1)
      {:trace_delivered, ^worker, ^marker} -> calls
    after
      1_000 -> flunk("液体指纹 trace 投递屏障未完成")
    end
  end
end
