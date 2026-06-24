defmodule SceneServer.Voxel.Field.DiodeTest do
  @moduledoc """
  建设系统 · C4b 深半导体:二极管(单向导通)。正偏(anode/in_face 侧更近电源)→ 回路通、
  load :powered + 电流;反偏(anode 背向电源)→ 二极管被剪断、回路断、load 失电、无电流。

  方向判定用「离电源跳数」(hop-bias)而非有向 SCC:电源无极性,SCC 对单回路无效(反偏只会
  让电流绕另一圈)。详见 CircuitComponentAnalysis 的 cut_reverse_diodes。
  """
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.Field.{CircuitComponentAnalysis, FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.CircuitCurrentKernel
  alias SceneServer.Voxel.{NormalBlockData, Storage, Types}

  @iron 5
  @power_block 6
  @load_block 7
  @diode 22

  # state_flags bits[0..2] 方向码:1=+x(in=x_neg→out=x_pos)、2=-x(in=x_pos→out=x_neg)。
  @forward_plus_x 1
  @reverse_minus_x 2

  @diode_coord {1, 0, 0}
  @load_coord {2, 0, 0}

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp put_solid(storage, coord, material_id, state_flags) do
    Storage.put_solid_block(
      storage,
      coord,
      NormalBlockData.new(material_id, state_flags: state_flags)
    )
  end

  # 闭合环:power(0,0,0) - diode(1,0,0) - load(2,0,0) - iron 回流 - 回 power。
  defp loop(diode_code) do
    [
      {{0, 0, 0}, @power_block, 0},
      {@diode_coord, @diode, diode_code},
      {@load_coord, @load_block, 0},
      {{2, 1, 0}, @iron, 0},
      {{2, 2, 0}, @iron, 0},
      {{1, 2, 0}, @iron, 0},
      {{0, 2, 0}, @iron, 0},
      {{0, 1, 0}, @iron, 0}
    ]
    |> Enum.reduce(Storage.new(7, {0, 0, 0}), fn {coord, m, sf}, acc ->
      put_solid(acc, coord, m, sf)
    end)
  end

  defp region do
    FieldRegion.new(%{
      region_id: 601,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {2, 2, 0}},
      kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
      source_points: [
        %{
          macro_index: Types.macro_index!({0, 0, 0}),
          field_type: :electric_potential,
          value: 120.0
        }
      ]
    })
  end

  defp tick(diode_code) do
    region = region()
    context = KernelContext.new(region, 7, loop(diode_code), dt_ms: 100)
    {:cont, updated, effects} = CircuitCurrentKernel.tick(region, context, %{})
    {updated, effects}
  end

  defp powered_tag(effects, macro_index) do
    Enum.find_value(effects, fn
      {:set_tag, %{macro_index: ^macro_index, add: add, remove: remove}} ->
        cond do
          :powered in add -> :add
          :powered in remove -> :remove
          true -> nil
        end

      _other ->
        nil
    end)
  end

  defp current_at(updated, macro_index) do
    updated |> FieldRegion.get_layer(:electric_current) |> FieldLayer.get(macro_index)
  end

  test "正偏二极管(+x,anode 侧近电源)→ load 通电、有电流" do
    load_macro = Types.macro_index!(@load_coord)
    {updated, effects} = tick(@forward_plus_x)

    assert powered_tag(effects, load_macro) == :add
    assert current_at(updated, load_macro) > 0.0
  end

  test "反偏二极管(-x,anode 背向电源)→ 回路断、load 失电、无电流" do
    load_macro = Types.macro_index!(@load_coord)
    {updated, effects} = tick(@reverse_minus_x)

    assert powered_tag(effects, load_macro) == :remove
    assert current_at(updated, load_macro) == 0.0
  end

  test "state_flags=0 回退材料 conduction_axis 默认(+x)→ 等同正偏(无朝向放置的安全默认)" do
    load_macro = Types.macro_index!(@load_coord)
    # 0 = 无 per-cell 朝向 → 用材料默认 conduction_axis(diode 材料 = 1 = +x)。
    {updated, effects} = tick(0)

    assert powered_tag(effects, load_macro) == :add
    assert current_at(updated, load_macro) > 0.0
  end

  test "拓扑:正偏 active_circuit?=true、反偏=false(同一回路只翻转二极管朝向)" do
    region = region()

    forward_proj = SceneServer.Voxel.Field.ParticipantProjection.build(loop(@forward_plus_x))
    reverse_proj = SceneServer.Voxel.Field.ParticipantProjection.build(loop(@reverse_minus_x))

    assert CircuitComponentAnalysis.active_circuit?(region, forward_proj)
    refute CircuitComponentAnalysis.active_circuit?(region, reverse_proj)
  end
end
