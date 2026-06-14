defmodule SceneServer.StateClassDeclarationTest do
  @moduledoc """
  PERS-5 一致性守护:断言 scene_server 侧状态持有者的**自声明**(`use MmoContracts.StateClassed`)
  与 `MmoContracts.StateRegistry` 中央清单一致。

  与 `DataService.StateClassDeclarationTest` 同模式,覆盖 scene_server 的清单条目。
  """
  use ExUnit.Case, async: true

  alias MmoContracts.StateRegistry

  @scene_entries Enum.filter(StateRegistry.entries(), &(&1.app == :scene_server))
  @scene_holders Enum.map(@scene_entries, & &1.holder)

  test "清单覆盖 scene_server 四类核心持有者" do
    assert SceneServer.Voxel.Storage in @scene_holders
    assert SceneServer.PlayerCharacter in @scene_holders
    assert SceneServer.Voxel.Field.FieldRegion in @scene_holders
    assert SceneServer.Combat.EffectEvent in @scene_holders
  end

  for entry <- @scene_entries do
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
