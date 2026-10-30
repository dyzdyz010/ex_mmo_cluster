defmodule VoxelRegion.StaticL0CheckTest do
  @moduledoc "只测试：判定器必须拒绝故意损坏的数量、焓、CV、XYZ、装页顺序和 due；不启动 World。"
  use ExUnit.Case, async: true
  alias VoxelRegion.TestSupport.StaticL0Check, as: Check

  test "逐步比较接受同一结果，六类语义损坏与空运行不能伪装通过" do
    step = %{identity: %{cv: 123, page: {0, {-2, 3, -4}}}, quantities: %{{-65, 200, -193} => 512},
      enthalpy_j: 10_000.0, due_ms: 100, material: 21}
    reference = [step]
    assert :ok = Check.compare_steps(reference, reference)
    bad = [put_in(step.quantities[{-65, 200, -193}], 511), %{step | enthalpy_j: 9_999.0},
      put_in(step.identity.cv, 124), put_in(step.identity.page, {0, {-2, 0, -4}}),
      %{step | due_ms: 150}, %{step | material: 0}]
    for changed <- bad, do: assert({:error, _} = Check.compare_steps(reference, [changed]))
    assert {:error, _} = Check.compare_steps(reference, [])
    assert {:error, _} = Check.compare_steps([], [])
  end

  test "漏装页、先读后装、退休后未重装均失败" do
    key = {0, {-2, 3, -4}}
    load = %{action: :resident, page: key, at: 10}
    read = %{action: :read, page: key, at: 20}
    assert :ok = Check.verify_reads([load, read])
    assert {:error, _} = Check.verify_reads([read])
    assert {:error, _} = Check.verify_reads([%{read | at: 5}, load])
    assert {:error, _} = Check.verify_reads([load, %{action: :retire, page: key, at: 15}, read])
    assert {:error, :no_reads} = Check.verify_reads([load])
  end

  test "精确退休集合不能少退、多退、退 recorded 或粗层" do
    p = {0, {0, 0, 0}}
    q = {0, {1, 0, 0}}
    event = %{eligible: MapSet.new([p, q]), resident: MapSet.new([p, q]), staged: MapSet.new(),
      required: MapSet.new([q]), persistence_blocked: MapSet.new(), retired: MapSet.new([p]),
      cores: %{p => %{source_only: true, core: :ok}}}
    assert :ok = Check.verify_retirement(event)
    assert {:error, _} = Check.verify_retirement(%{event | retired: MapSet.new()})
    assert {:error, _} = Check.verify_retirement(%{event | retired: MapSet.new([p, q])})
    assert {:error, :unproven_retirement} = Check.verify_retirement(put_in(event.cores[p].source_only, false))
    coarse = {1, {0, 0, 0}}
    coarse_event = %{event | eligible: MapSet.new([coarse]), resident: MapSet.new([coarse]),
      required: MapSet.new(), retired: MapSet.new([coarse])}
    assert {:error, :coarse_retirement} = Check.verify_retirement(coarse_event)
  end
end
