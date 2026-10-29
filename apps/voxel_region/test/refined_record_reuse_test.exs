defmodule VoxelRegion.RefinedRecordReuseTest do
  @moduledoc "只测试：已接纳的紧凑槽直接投影记录字节；纯输入，不启动 World／数据库。"
  use ExUnit.Case, async: false
  alias MmoContracts.Voxel.{Payload, Refined}
  alias VoxelRegion.World.{Canonical, Payloads}

  test "冷载荷不逐槽重编码，冷暖投影与旧 map 的协议字节相同" do
    owner = {7, 3}
    cell = {-63, 65, 130}
    region = {-1, 1, 2}
    input = Map.new(0..32, fn slot -> {slot, {11 + rem(slot, 2), owner}} end)
    refute Enum.to_list(input) == Enum.sort(input)
    instance = %{definition_id: <<1::256>>, anchor: {-504, 520, 1040}, orientation: 0}
    state = %{seq: 1, cv: 123, refined: %{}, refined_owners: %{}, refined_regions: %{},
      instances: %{owner => instance}, macro_owner_regions: %{},
      liquid_regions: %{}, attachments: %{}, attachment_regions: %{}}
      |> Canonical.put_refined(cell, input)
    base = %Payload{level: 0, region: region}
    index = Payload.cell_index(Payload.local(region, cell))
    expected = Refined.slot_records(input)

    {{cold, warm, after_state}, calls} = count_records(fn ->
      {cold, next} = Payloads.with_refined(state, base)
      {warm, after_state} = Payloads.with_refined(next, base)
      {cold, warm, after_state}
    end)
    assert cold.refined_encoding.cells == %{index => {33, expected}}
    assert cold == warm
    assert Refined.encode(cold.refined_encoding, cold.instances) ==
      Refined.encode(%{index => input}, %{owner => instance})
    assert calls == 0
    assert after_state == state
  end

  defp count_records(action) do
    mfa = {Refined, :slot_record, 1}
    assert {:module, Refined} = Code.ensure_loaded(Refined)
    parent = self()
    {worker, monitor} = spawn_monitor(fn ->
      receive do
        :run ->
          send(parent, {:result, self(), action.()})
          receive do: (:stop -> :ok)
      end
    end)
    sessions = :trace.session_info(:all)
    session = :trace.session_create(:refined_record_reuse, self(), [])
    try do
      assert :trace.function(session, mfa, true, [:local]) == 1
      assert :trace.process(session, worker, true, [:call, :arity]) == 1
      send(worker, :run)
      result = receive do
        {:result, ^worker, result} -> result
      after
        5_000 -> flunk("细化槽编码投影没有完成")
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
      1_000 -> flunk("细化记录 trace 投递屏障未完成")
    end
  end
end
