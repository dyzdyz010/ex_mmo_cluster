defmodule SceneServer.Voxel.Field.CellSimNativeTest do
  # 梯队2 step2.7a/2.7b:Rust ResourceArc<FieldLayerSim> 脚手架 + 句柄计算 NIF 数值等价。
  # 电势等价测试用 AttributeCatalog 单例,故 async: false。
  use ExUnit.Case, async: false

  alias SceneServer.Native.FieldKernel
  alias SceneServer.Voxel.{AttributeCatalog, NormalBlockData, Storage, Types}
  alias SceneServer.Voxel.Field.FieldLayer
  alias SceneServer.Voxel.Field.NativeBackend.ConductionPathInput
  alias SceneServer.Voxel.Field.ParticipantProjection

  @iron 5
  @power_block 6

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

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

  # 梯队2 step2.7b:propagate_electric_potential_sim 句柄版 vs 旧路径(potential + ionization 两层)。
  test "propagate_electric_potential_sim 与旧路径数值等价(两层)" do
    aabb = {{0, 0, 0}, {3, 1, 0}}
    projection = ParticipantProjection.build(conductive_storage())
    entries = ConductionPathInput.conduction_entries(projection, aabb)
    sources = [{Types.macro_index!({0, 0, 0}), 120.0}]

    # 旧路径:NIF + apply 到两 FieldLayer(potential merge;ionization clear+apply)。
    {potential_cells, ionization_cells} =
      FieldKernel.propagate_electric_potential(sources, entries, aabb, [])

    pot_layer = apply_cells(FieldLayer.new(baseline: 0.0, threshold: 0.0001), potential_cells)

    ion_layer =
      FieldLayer.new(baseline: 0.0, threshold: 0.0001)
      |> clear_in_aabb(aabb)
      |> apply_cells(ionization_cells)

    old_pot = FieldLayer.active_cells(pot_layer, aabb, 0.0001)
    old_ion = FieldLayer.active_cells(ion_layer, aabb, 0.0001)

    # 新路径:两 CellSim + propagate_electric_potential_sim。
    pot_sim = FieldKernel.cell_sim_new(0.0, 0.0001, "float")
    ion_sim = FieldKernel.cell_sim_new(0.0, 0.0001, "float")

    assert :ok =
             FieldKernel.propagate_electric_potential_sim(
               pot_sim,
               ion_sim,
               sources,
               entries,
               aabb
             )

    new_pot = FieldKernel.cell_sim_active_cells(pot_sim, aabb, 0.0001)
    new_ion = FieldKernel.cell_sim_active_cells(ion_sim, aabb, 0.0001)

    assert new_pot == old_pot
    assert new_ion == old_ion
    # 非平凡:确有电势产出。
    assert old_pot != []
  end

  defp apply_cells(layer, cells) do
    Enum.reduce(cells, layer, fn {idx, value}, acc -> FieldLayer.put(acc, idx, value) end)
  end

  defp clear_in_aabb(layer, {{x0, y0, z0}, {x1, y1, z1}}) do
    Enum.reduce(
      for(x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x, y, z}),
      layer,
      fn coord, acc -> FieldLayer.put(acc, Types.macro_index!(coord), 0.0) end
    )
  end

  defp conductive_storage do
    Storage.new(7, {0, 0, 0})
    |> put_solid({0, 0, 0}, @power_block)
    |> put_solid({1, 0, 0}, @iron)
    |> put_solid({2, 0, 0}, @iron)
    |> put_solid({3, 0, 0}, @iron)
  end

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end
end
