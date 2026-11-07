defmodule VoxelRegion.ProjectileOrderTest do
  @moduledoc """
  只测试：投射物一轮采样的交付次序。结果按此次序逐个提交（world seq、命中先后），次序 = 拟态 id
  {创建事务 seq, n} 升序即发射次序；不取拟态表的 map 遍历次序（40 > 32 键时 OTP 27 与 29 互逆、都不是键序）。
  纯值状态 + 记录型后端，不启动 World、数据库或网络。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.World.Projectiles

  defmodule Backend do
    @moduledoc "只测试：原样返回收到的投射物 id 次序。"
    def poll(shots, _cv), do: Enum.map(shots, &elem(&1, 0))
  end

  test "一轮采样按拟态 id（发射次序）交给后端" do
    ids = for seq <- 1..40, do: {seq, 0}
    semblances = Map.new(ids, &{&1, %{projectile_source: :test}})
    # 非投射物拟态不进采样。
    semblances = Map.put(semblances, {41, 0}, %{})
    refute Map.keys(semblances) == Enum.sort(Map.keys(semblances))

    state = %{projectile_task: nil, projectile_backend: Backend, cv: 7, thermal: %{semblances: semblances}}
    assert Task.await(Projectiles.poll(state).projectile_task) == ids
  end
end
