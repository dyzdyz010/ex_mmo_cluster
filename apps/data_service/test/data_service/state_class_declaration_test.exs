defmodule DataService.StateClassDeclarationTest do
  @moduledoc """
  PERS-5 一致性守护:断言 data_service 侧状态持有者的**自声明**(`use MmoContracts.StateClassed`)
  与 `MmoContracts.StateRegistry` 中央清单一致。

  迁移期:随各梯队把更多持有者接入 StateClassed,本测试自动覆盖 data_service 的清单条目。
  """
  use ExUnit.Case, async: true

  alias MmoContracts.StateRegistry

  @data_service_entries Enum.filter(StateRegistry.entries(), &(&1.app == :data_service))
  @data_service_holders Enum.map(@data_service_entries, & &1.holder)

  test "清单覆盖 data_service 核心持有者" do
    assert DataService.Voxel.ChunkSnapshotStore in @data_service_holders
    assert DataService.Voxel.MapLedgerStore in @data_service_holders
    assert DataService.Schema.Account in @data_service_holders
  end

  for entry <- @data_service_entries do
    @entry entry
    test "#{inspect(entry.holder)} 自声明 == 清单(#{entry.state_class})" do
      assert Code.ensure_loaded?(@entry.holder),
             "持有者模块 #{inspect(@entry.holder)} 未编译/不存在"

      assert function_exported?(@entry.holder, :__state_class__, 0),
             "#{inspect(@entry.holder)} 未 use MmoContracts.StateClassed(PERS-5 自声明缺失)"

      assert @entry.holder.__state_class__() == @entry.state_class,
             "#{inspect(@entry.holder)} 声明 #{inspect(@entry.holder.__state_class__())} 与清单 #{inspect(@entry.state_class)} 不一致"
    end
  end
end
