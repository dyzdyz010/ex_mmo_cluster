defmodule SceneServer.Voxel.Reaction.Rules do
  @moduledoc """
  涌现反应规范规则表(功能完善 · 反应层 R1)。

  单一真相源,`Engine` 对它求值。骨架阶段只 seed 一条 demo 相变(冰熔化)立住回路;燃烧 / 相变补全 /
  电→世界 只是往这里加规则(+ 必要的 coded reaction kernel)。新增 kernel 行为无须改 Engine——数据化优先。
  """

  alias SceneServer.Voxel.Reaction.Rule

  # demo:冰 + 温度 ≥ 自身 melting_point(0℃)→ 水。回路 PoC。
  @ice_melts Rule.new!(
               id: :ice_melts,
               kind: :phase_transition,
               from_material: :ice,
               condition: {:temperature, :gte, {:material_threshold, "melting_point"}},
               to_material: :water,
               priority: 0
             )

  @all [@ice_melts]

  @doc "全部反应规则。"
  @spec all() :: [Rule.t()]
  def all, do: @all

  @doc "某 from 材料名(相变)适用的规则。"
  @spec for_material(atom()) :: [Rule.t()]
  def for_material(name) when is_atom(name) do
    Enum.filter(@all, &(&1.kind == :phase_transition and &1.from_material == name))
  end
end
