defmodule SceneServer.Voxel.Field.CellSimNativeTest do
  # 梯队2 step2.7a:Rust ResourceArc<FieldLayerSim> 脚手架 NIF 冒烟(数据留 Rust)。
  # 句柄计算 NIF(diffuse_temperature_sim / propagate_electric_potential_sim)的端到端正确性
  # 由 FieldKernelNativeTest(经 NativeBackend)+ TemperatureFieldTest / ElectricFieldTest 验证;
  # 2.7c 原子 flip 后旧向量 NIF 已删,故此处不再保留 old-vs-new 等价对照。
  use ExUnit.Case, async: true

  alias SceneServer.Native.FieldKernel
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
end
