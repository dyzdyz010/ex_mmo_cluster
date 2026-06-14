defmodule SceneServer.Voxel.Field.FieldKernelNativeTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{AttributeCatalog, NormalBlockData, Storage, Types}
  alias SceneServer.Voxel.Field.{FieldLayer, NativeBackend, ParticipantProjection}
  alias SceneServer.Voxel.Field.NativeBackend.ConductionPathInput

  @iron 5
  @power_block 6

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "returns only a conductive macro path for identical projection input" do
    source = Types.macro_index!({0, 1, 0})
    target = Types.macro_index!({3, 1, 0})

    assert {:ok, native_path} =
             NativeBackend.find_conduction_path(
               ParticipantProjection.build(conduction_storage()),
               {{0, 0, 0}, {3, 1, 0}},
               source,
               target,
               120.0,
               FieldLayer.new(),
               512
             )

    assert native_path == [
             source,
             Types.macro_index!({0, 0, 0}),
             Types.macro_index!({1, 0, 0}),
             Types.macro_index!({2, 0, 0}),
             Types.macro_index!({3, 0, 0}),
             target
           ]
  end

  test "returns frontier_exhausted as a native contract error without field mutation" do
    source = Types.macro_index!({0, 1, 0})
    target = Types.macro_index!({3, 1, 0})

    assert {:error, :frontier_exhausted} =
             NativeBackend.find_conduction_path(
               ParticipantProjection.build(conduction_storage()),
               {{0, 0, 0}, {3, 1, 0}},
               source,
               target,
               120.0,
               FieldLayer.new(),
               1
             )
  end

  test "crops native conduction entries to the requested field AABB" do
    inside = Types.macro_index!({0, 0, 0})
    outside = Types.macro_index!({8, 8, 8})

    projection =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0})
      |> put_solid({8, 8, 8})
      |> ParticipantProjection.build()

    entries =
      projection
      |> ConductionPathInput.conduction_entries({{0, 0, 0}, {1, 1, 1}})
      |> Enum.map(&elem(&1, 0))

    assert entries == [inside]
    refute outside in entries
  end

  test "computes a sparse temperature diffusion tick through the field backend" do
    source = Types.macro_index!({3, 3, 3})
    neighbor = Types.macro_index!({4, 3, 3})

    layer =
      FieldLayer.new(baseline: 20, quantization: :float)
      |> FieldLayer.put(source, 800.0)

    # 梯队2 step2.7c:句柄 NIF 原地 mutate layer.cell_sim,返回 :ok;断言改查 layer 状态(delta)。
    assert :ok =
             NativeBackend.diffuse_temperature(
               layer,
               {{0, 0, 0}, {7, 7, 7}},
               [source, neighbor],
               nil,
               0.1,
               0.1,
               0.0,
               1.0
             )

    assert FieldLayer.get_delta(layer, source) < 780.0
    assert FieldLayer.get_delta(layer, neighbor) > 0.0
  end

  test "propagates electric potential and ionization through the field backend" do
    source = Types.macro_index!({0, 0, 0})
    neighbor = Types.macro_index!({1, 0, 0})

    potential_layer = FieldLayer.new()
    ionization_layer = FieldLayer.new()

    # 梯队2 step2.7c:句柄 NIF 原地 mutate 两层句柄,返回 :ok;断言改查 layer 状态。
    assert :ok =
             NativeBackend.propagate_electric_potential(
               potential_layer,
               ionization_layer,
               [%{macro_index: source, field_type: :electric_potential, value: 100.0}],
               {{0, 0, 0}, {3, 3, 3}},
               ParticipantProjection.build(
                 Storage.new(7, {0, 0, 0})
                 |> put_solid({0, 0, 0})
                 |> put_solid({1, 0, 0})
               )
             )

    assert_in_delta FieldLayer.get(potential_layer, source), 100.0, 0.001
    assert FieldLayer.get(potential_layer, neighbor) > 0.0
    assert FieldLayer.get(potential_layer, neighbor) < 100.0
    assert FieldLayer.get(ionization_layer, source) == 5.0
  end

  test "finds a native dielectric-breakdown path through empty medium" do
    source = Types.macro_index!({0, 0, 0})
    target = Types.macro_index!({3, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @power_block)
      |> put_solid({3, 0, 0}, @iron)

    assert {:ok, path} =
             NativeBackend.find_discharge_path(
               storage,
               {{0, 0, 0}, {3, 0, 0}},
               source,
               target,
               120.0,
               FieldLayer.new(),
               32
             )

    assert path == [
             source,
             Types.macro_index!({1, 0, 0}),
             Types.macro_index!({2, 0, 0}),
             target
           ]
  end

  test "native dielectric-breakdown path rejects under-threshold potential" do
    source = Types.macro_index!({0, 0, 0})
    target = Types.macro_index!({3, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @power_block)
      |> put_solid({3, 0, 0}, @iron)

    assert {:error, :no_discharge_path} =
             NativeBackend.find_discharge_path(
               storage,
               {{0, 0, 0}, {3, 0, 0}},
               source,
               target,
               2.0,
               FieldLayer.new(),
               32
             )
  end

  defp conduction_storage do
    Storage.new(7, {0, 0, 0})
    |> put_solid({0, 1, 0})
    |> put_solid({3, 1, 0})
    |> put_solid({0, 0, 0})
    |> put_solid({1, 0, 0})
    |> put_solid({2, 0, 0})
    |> put_solid({3, 0, 0})
  end

  defp put_solid(storage, coord) do
    put_solid(storage, coord, @iron)
  end

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end
end
