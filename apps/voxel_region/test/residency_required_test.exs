defmodule VoxelRegion.ResidencyRequiredTest do
  @moduledoc """
  只测试：已有 owner 错误时不构造无用的驻留闭包，且保留显式阻退。
  纯合法输入，不启动 World／数据库；单 MFA 只记录独立进程的调用次数。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World.{PageLoad, Pages, Residency}

  test "天然活动未登记直接阻退，不先展开观察或准备的整树闭包" do
    state = %{
      source: VoxelRegion.GeneratedStore,
      thermal: %{active: false, sources: %{}, semblances: %{}, config: %{}},
      thermal_work: VoxelRegion.ThermalWork.new(), thermal_run: nil,
      bodies: %{}, damage: %{}, properties: %{materials: %{}},
      liquid_active: MapSet.new(), liquid_bounds: nil, pending_casts: %{},
      canonical_subs: %{self() => {{-2, 1, -3}, {-1, 2, -2}}}, replica_subs: %{},
      simulation_windows: %{}, input_ready: :queue.new(), input_current: nil,
      page_load: PageLoad.new(), pages: Pages.new(), instances: %{},
      refined_region_owners: %{}, macro_owner_regions: %{},
      attachment_regions: %{}, attachment_owners: %{}
    }
    error = {:error, {:thermal, {:natural_activity_unregistered, VoxelRegion.GeneratedStore}}}
    {result, calls} = count_closures(fn -> Residency.required(state) end)
    assert result == error
    assert calls == 0

    # 全量准备也不能隐藏 owner 的具体阻退原因；两者均禁止退休。
    all = put_in(state.page_load.sim, %{request: :all})
    assert Residency.required(all) == error
  end

  defp count_closures(action) do
    mfa = {Pages, :residency_closure, 3}
    assert {:module, Pages} = Code.ensure_loaded(Pages)
    parent = self()
    {worker, monitor} = spawn_monitor(fn ->
      receive do
        :run ->
          send(parent, {:result, self(), action.()})
          receive do: (:stop -> :ok)
      end
    end)
    sessions = :trace.session_info(:all)
    session = :trace.session_create(:residency_required_calls, self(), [])

    try do
      assert :trace.function(session, mfa, true, [:local]) == 1
      assert :trace.process(session, worker, true, [:call, :arity]) == 1
      send(worker, :run)
      result = receive do
        {:result, ^worker, result} -> result
      after
        5_000 -> flunk("驻留需求纯计算没有完成")
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
      1_000 -> flunk("驻留闭包 trace 投递屏障未完成")
    end
  end
end
