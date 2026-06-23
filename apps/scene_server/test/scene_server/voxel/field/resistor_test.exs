defmodule SceneServer.Voxel.Field.ResistorTest do
  @moduledoc """
  建设系统 · 半导体梯队 a:电阻——被动电阻件。中等导电(1.5)入电路图但抬升串联电阻 →
  同回路电流低于全铁导线;且电阻是 :conductor 非 :load(不置 :powered、不 I²R 发热)。
  """
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.CircuitCurrentKernel
  alias SceneServer.Voxel.{NormalBlockData, Storage, Types}

  @iron 5
  @power_block 6
  @load_block 7
  @resistor 20

  # High current limit so the conductor-resistance difference isn't masked by the
  # power source's default 20A clamp.
  @opts %{current_limit_amps: 1_000.0}

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end

  # A closed loop: power → conductor → load → conductor ring back. `conductor` is
  # the material used for the 6 non-source/non-load cells.
  defp loop(conductor) do
    [
      {{0, 0, 0}, @power_block},
      {{1, 0, 0}, conductor},
      {{2, 0, 0}, @load_block},
      {{2, 1, 0}, conductor},
      {{2, 2, 0}, conductor},
      {{1, 2, 0}, conductor},
      {{0, 2, 0}, conductor},
      {{0, 1, 0}, conductor}
    ]
    |> Enum.reduce(Storage.new(7, {0, 0, 0}), fn {coord, m}, acc -> put_solid(acc, coord, m) end)
  end

  defp region do
    FieldRegion.new(%{
      region_id: 503,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {2, 2, 0}},
      kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
      source_points: [
        %{macro_index: Types.macro_index!({0, 0, 0}), field_type: :electric_potential, value: 120.0}
      ]
    })
  end

  defp tick(conductor) do
    region = region()
    context = KernelContext.new(region, 7, loop(conductor), dt_ms: 100)
    CircuitCurrentKernel.tick(region, context, @opts)
  end

  defp max_current(conductor) do
    {:cont, updated, _effects} = tick(conductor)

    updated
    |> FieldRegion.get_layer(:electric_current)
    |> FieldLayer.active_cells(updated.aabb, 0)
    |> Enum.map(fn {_macro, amps} -> amps end)
    |> Enum.max(fn -> 0.0 end)
  end

  test "resistor conductors carry less current than iron (passive series resistance)" do
    iron_current = max_current(@iron)
    resistor_current = max_current(@resistor)

    assert iron_current > 0.0, "iron loop should conduct"
    assert resistor_current > 0.0, "resistor loop should still conduct (it IS a conductor)"

    assert resistor_current < iron_current,
           "resistor #{resistor_current} should carry less than iron #{iron_current}"
  end

  test "resistor is a conductor, not a load: no :powered tag, no I²R heat on it" do
    {:cont, _updated, effects} = tick(@resistor)
    resistor_macro = Types.macro_index!({2, 1, 0})
    load_macro = Types.macro_index!({2, 0, 0})

    # The load block still energizes (sanity: the circuit is closed + powered).
    assert Enum.any?(effects, fn
             {:set_tag, %{macro_index: ^load_macro, add: add}} -> :powered in add
             _other -> false
           end)

    # The resistor cell is NOT a load: never tagged :powered, never gets I²R heat.
    refute Enum.any?(effects, fn
             {:set_tag, %{macro_index: ^resistor_macro, add: add}} -> :powered in add
             _other -> false
           end)

    refute Enum.any?(effects, fn
             {:write_voxel_attribute, %{attribute: :temperature, macro_index: ^resistor_macro}} ->
               true

             _other ->
               false
           end)
  end
end
