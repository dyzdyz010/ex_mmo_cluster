defmodule SceneServer.Voxel.Field.CellSimNativeTest do
  # 梯队2 step2.7a:Rust ResourceArc<FieldLayerSim> 脚手架 NIF 冒烟(数据留 Rust)。
  use ExUnit.Case, async: true

  alias SceneServer.Native.FieldKernel
  alias SceneServer.Voxel.Field.FieldLayer
  alias SceneServer.Voxel.Types

  test "new returns a resource handle (reference)" do
    sim = FieldKernel.cell_sim_new(20.0, 0.0001, "float")
    assert is_reference(sim)
  end

  test "put/get round-trips absolute value;未设读 baseline" do
    sim = FieldKernel.cell_sim_new(20.0, 0.0001, "float")
    idx = Types.macro_index!({1, 2, 3})

    assert FieldKernel.cell_sim_get(sim, idx) == 20.0
    assert :ok = FieldKernel.cell_sim_put(sim, idx, 35.0)
    assert FieldKernel.cell_sim_get(sim, idx) == 35.0
  end

  test "below-threshold delta 稀疏丢弃,读回 baseline" do
    sim = FieldKernel.cell_sim_new(20.0, 0.5, "float")
    idx = Types.macro_index!({0, 0, 0})

    # delta 0.2 < threshold 0.5 → 不存储。
    assert :ok = FieldKernel.cell_sim_put(sim, idx, 20.2)
    assert FieldKernel.cell_sim_get(sim, idx) == 20.0
  end

  test "integer quantization 四舍五入 delta" do
    sim = FieldKernel.cell_sim_new(20.0, 0.0001, "integer")
    idx = Types.macro_index!({2, 0, 0})

    # baseline 20,delta = 23.6 - 20 = 3.6 → round 4 → 绝对 24.0。
    assert :ok = FieldKernel.cell_sim_put(sim, idx, 23.6)
    assert FieldKernel.cell_sim_get(sim, idx) == 24.0
  end

  test "active_cells 过 aabb + epsilon,按 idx 升序" do
    sim = FieldKernel.cell_sim_new(20.0, 0.0001, "float")
    i0 = Types.macro_index!({0, 0, 0})
    i17 = Types.macro_index!({1, 1, 0})
    i_far = Types.macro_index!({15, 15, 15})

    FieldKernel.cell_sim_put(sim, i0, 25.0)
    FieldKernel.cell_sim_put(sim, i17, 27.0)
    FieldKernel.cell_sim_put(sim, i_far, 29.0)

    cells = FieldKernel.cell_sim_active_cells(sim, {{0, 0, 0}, {1, 1, 0}}, 0.0001)
    assert cells == [{i0, 25.0}, {i17, 27.0}]
  end

  test "句柄独立:两个 sim 互不影响" do
    a = FieldKernel.cell_sim_new(20.0, 0.0001, "float")
    b = FieldKernel.cell_sim_new(20.0, 0.0001, "float")
    idx = Types.macro_index!({3, 3, 3})

    FieldKernel.cell_sim_put(a, idx, 50.0)
    assert FieldKernel.cell_sim_get(a, idx) == 50.0
    assert FieldKernel.cell_sim_get(b, idx) == 20.0
  end

  # 梯队2 step2.7b:diffuse_temperature_sim 句柄版 vs 旧 diffuse_temperature + FieldLayer.apply
  # 数值等价(含相邻 candidates 验证双缓冲:邻居读全取旧态)。
  test "diffuse_temperature_sim 与旧路径数值逐位等价" do
    hot = Types.macro_index!({1, 1, 1})

    neighbors =
      for c <- [{2, 1, 1}, {0, 1, 1}, {1, 2, 1}, {1, 0, 1}, {1, 1, 2}, {1, 1, 0}],
          do: Types.macro_index!(c)

    candidates = [hot | neighbors]
    aabb = {{0, 0, 0}, {3, 3, 3}}
    thermal = []
    {diffusion_s, ambient_dt_s, ambient_loss, cell_size} = {1.0, 1.0, 0.0, 0.05}

    # 旧路径:FieldLayer(初始热源 delta 100)→ diffuse_temperature NIF → apply(put_delta SET)。
    cells = [{hot, 100.0}]

    new_deltas =
      FieldKernel.diffuse_temperature(
        cells,
        candidates,
        aabb,
        thermal,
        diffusion_s,
        ambient_dt_s,
        ambient_loss,
        cell_size
      )

    old_layer =
      FieldLayer.new(baseline: 0.0, threshold: 0.0001)
      |> FieldLayer.put_delta(hot, 100.0)

    old_layer =
      Enum.reduce(new_deltas, old_layer, fn {idx, d}, l -> FieldLayer.put_delta(l, idx, d) end)

    old_active = FieldLayer.active_cells(old_layer, aabb, 0.0001)

    # 新路径:CellSim(同初始)→ diffuse_temperature_sim 原地演化。
    sim = FieldKernel.cell_sim_new(0.0, 0.0001, "float")
    FieldKernel.cell_sim_put(sim, hot, 100.0)

    assert :ok =
             FieldKernel.diffuse_temperature_sim(
               sim,
               candidates,
               aabb,
               thermal,
               diffusion_s,
               ambient_dt_s,
               ambient_loss,
               cell_size
             )

    new_active = FieldKernel.cell_sim_active_cells(sim, aabb, 0.0001)

    assert new_active == old_active
    # 双缓冲生效:热源扩散到 6 邻居 + 自身衰减,>1 个 active cell。
    assert length(new_active) > 1
  end
end
