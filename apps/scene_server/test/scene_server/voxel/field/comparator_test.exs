defmodule SceneServer.Voxel.Field.ComparatorTest do
  @moduledoc """
  建设系统 · 半导体梯队 a:比较器/阈值门——闭环中 logic_threshold>0 的 cell 比较节点电位与
  阈值(60V),≥ 置 :signal_high、< 去之(模拟量→数字逻辑)。源电压拉到 120V 触发、40V 不触发。
  """
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.CircuitCurrentKernel
  alias SceneServer.Voxel.{NormalBlockData, Storage, Types}

  @iron 5
  @power_block 6
  @load_block 7
  @comparator 21

  @comparator_coord {1, 0, 0}
  @iron_coord {2, 1, 0}

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end

  # Closed loop with a comparator cell adjacent to the power source.
  defp loop do
    [
      {{0, 0, 0}, @power_block},
      {@comparator_coord, @comparator},
      {{2, 0, 0}, @load_block},
      {@iron_coord, @iron},
      {{2, 2, 0}, @iron},
      {{1, 2, 0}, @iron},
      {{0, 2, 0}, @iron},
      {{0, 1, 0}, @iron}
    ]
    |> Enum.reduce(Storage.new(7, {0, 0, 0}), fn {coord, m}, acc -> put_solid(acc, coord, m) end)
  end

  defp region(source_voltage) do
    FieldRegion.new(%{
      region_id: 503,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {2, 2, 0}},
      kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
      source_points: [
        %{
          macro_index: Types.macro_index!({0, 0, 0}),
          field_type: :electric_potential,
          value: source_voltage
        }
      ]
    })
  end

  defp effects(source_voltage) do
    region = region(source_voltage)
    context = KernelContext.new(region, 7, loop(), dt_ms: 100)
    {:cont, _updated, effects} = CircuitCurrentKernel.tick(region, context, %{})
    effects
  end

  defp signal_tag(effects, macro_index) do
    Enum.find_value(effects, fn
      {:set_tag, %{macro_index: ^macro_index, add: add, remove: remove}} ->
        cond do
          :signal_high in add -> :add
          :signal_high in remove -> :remove
          true -> nil
        end

      _other ->
        nil
    end)
  end

  test "comparator above threshold (120V source) → :signal_high set" do
    comparator_macro = Types.macro_index!(@comparator_coord)
    assert signal_tag(effects(120.0), comparator_macro) == :add
  end

  test "comparator below threshold (40V source) → :signal_high cleared" do
    comparator_macro = Types.macro_index!(@comparator_coord)
    assert signal_tag(effects(40.0), comparator_macro) == :remove
  end

  test "non-comparator (iron) cells never emit a :signal_high effect" do
    iron_macro = Types.macro_index!(@iron_coord)
    assert signal_tag(effects(120.0), iron_macro) == nil
  end
end
