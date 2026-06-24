defmodule SceneServer.Voxel.Field.TransistorTest do
  @moduledoc """
  建设系统 · C4b 深半导体:三极管(门控开关)+ 逻辑门。主通路(collector-emitter)仅当 base 面
  邻接的控制网络被 ≥ base_threshold 的电源驱动时导通,否则该三极管被剪断、主回路断。base 面不入
  导电图(传感输入),故 base 邻格可达性 = 控制网络是否被驱动。串联=AND、并联=OR。
  """
  use ExUnit.Case, async: false

  import Bitwise

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.CircuitCurrentKernel
  alias SceneServer.Voxel.{NormalBlockData, Storage, Types}

  @iron 5
  @power_block 6
  @load_block 7
  @transistor 23

  # state_flags:main 轴码 bits[0..2]=1(+x → collector/emitter on x);base 面 bits[6..8]=6(z_pos)。
  @sf_main_x_base_zpos 6 <<< 6 ||| 1

  @load_coord {2, 0, 0}
  @base_coord {1, 0, 1}

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

  # 主回路:power(0,0,0) - transistor(1,0,0) c/e - load(2,0,0) - iron 回流环 - 回 power。
  # base_cell:nil=base 面悬空(无控制)/ :power=base 被电源驱动 / :iron=base 有线但无源(未驱动)。
  defp storage(base_cell) do
    main =
      [
        {{0, 0, 0}, @power_block, 0},
        {{1, 0, 0}, @transistor, @sf_main_x_base_zpos},
        {@load_coord, @load_block, 0},
        {{2, 1, 0}, @iron, 0},
        {{2, 2, 0}, @iron, 0},
        {{1, 2, 0}, @iron, 0},
        {{0, 2, 0}, @iron, 0},
        {{0, 1, 0}, @iron, 0}
      ]

    cells =
      case base_cell do
        :power -> main ++ [{@base_coord, @power_block, 0}]
        :iron -> main ++ [{@base_coord, @iron, 0}]
        nil -> main
      end

    Enum.reduce(cells, Storage.new(7, {0, 0, 0}), fn {coord, m, sf}, acc ->
      put_solid(acc, coord, m, sf)
    end)
  end

  defp region(base_source?) do
    base_points =
      if base_source? do
        [
          %{
            macro_index: Types.macro_index!(@base_coord),
            field_type: :electric_potential,
            value: 120.0
          }
        ]
      else
        []
      end

    FieldRegion.new(%{
      region_id: 611,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {2, 2, 1}},
      kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
      source_points:
        [
          %{
            macro_index: Types.macro_index!({0, 0, 0}),
            field_type: :electric_potential,
            value: 120.0
          }
        ] ++ base_points
    })
  end

  defp tick(base_cell, base_source?) do
    region = region(base_source?)
    context = KernelContext.new(region, 7, storage(base_cell), dt_ms: 100)
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

  test "base 被电源驱动 → 三极管导通、load 通电、有电流" do
    load_macro = Types.macro_index!(@load_coord)
    {updated, effects} = tick(:power, true)

    assert powered_tag(effects, load_macro) == :add
    assert current_at(updated, load_macro) > 0.0
  end

  test "base 面悬空(无控制格)→ 三极管截止、回路断、load 失电、无电流" do
    load_macro = Types.macro_index!(@load_coord)
    {updated, effects} = tick(nil, false)

    assert powered_tag(effects, load_macro) == :remove
    assert current_at(updated, load_macro) == 0.0
  end

  test "base 有控制线但无源驱动 → 三极管截止(base 未被 ≥门限电源驱动)" do
    load_macro = Types.macro_index!(@load_coord)
    {updated, effects} = tick(:iron, false)

    assert powered_tag(effects, load_macro) == :remove
    assert current_at(updated, load_macro) == 0.0
  end

  # ── AND 门:两个三极管串联在主通路上,任一截止即断主路 → 仅两 base 都驱动时 load 通电 ──
  @and_load_coord {3, 0, 0}
  @and_base1_coord {1, 0, 1}
  @and_base2_coord {2, 0, 1}

  defp and_storage(base1?, base2?) do
    main = [
      {{0, 0, 0}, @power_block, 0},
      {{1, 0, 0}, @transistor, @sf_main_x_base_zpos},
      {{2, 0, 0}, @transistor, @sf_main_x_base_zpos},
      {@and_load_coord, @load_block, 0},
      {{3, 1, 0}, @iron, 0},
      {{2, 1, 0}, @iron, 0},
      {{1, 1, 0}, @iron, 0},
      {{0, 1, 0}, @iron, 0}
    ]

    cells =
      main
      |> maybe_base(base1?, @and_base1_coord)
      |> maybe_base(base2?, @and_base2_coord)

    Enum.reduce(cells, Storage.new(7, {0, 0, 0}), fn {coord, m, sf}, acc ->
      put_solid(acc, coord, m, sf)
    end)
  end

  defp maybe_base(cells, true, coord), do: cells ++ [{coord, @power_block, 0}]
  defp maybe_base(cells, false, _coord), do: cells

  defp and_region(base1?, base2?) do
    base_points =
      []
      |> maybe_base_source(base1?, @and_base1_coord)
      |> maybe_base_source(base2?, @and_base2_coord)

    FieldRegion.new(%{
      region_id: 612,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {3, 1, 1}},
      kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
      source_points:
        [
          %{
            macro_index: Types.macro_index!({0, 0, 0}),
            field_type: :electric_potential,
            value: 120.0
          }
        ] ++ base_points
    })
  end

  defp maybe_base_source(points, true, coord) do
    points ++
      [%{macro_index: Types.macro_index!(coord), field_type: :electric_potential, value: 120.0}]
  end

  defp maybe_base_source(points, false, _coord), do: points

  defp and_tick(base1?, base2?) do
    region = and_region(base1?, base2?)
    context = KernelContext.new(region, 7, and_storage(base1?, base2?), dt_ms: 100)
    {:cont, _updated, effects} = CircuitCurrentKernel.tick(region, context, %{})
    powered_tag(effects, Types.macro_index!(@and_load_coord))
  end

  test "AND 门(两三极管串联):仅两 base 都驱动 → load 通电" do
    assert and_tick(true, true) == :add
    assert and_tick(true, false) == :remove
    assert and_tick(false, true) == :remove
    assert and_tick(false, false) == :remove
  end
end
