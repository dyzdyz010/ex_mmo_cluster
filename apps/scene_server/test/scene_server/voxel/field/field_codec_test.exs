defmodule SceneServer.Voxel.Field.FieldCodecTest do
  # Phase 6 局部场最小目标:0x73 FieldRegionSnapshot / 0x74 FieldRegionDestroyed
  # wire codec roundtrip 测试。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldCodec, FieldLayer, FieldRegion}
  alias SceneServer.Voxel.Types

  describe "0x73 FieldRegionSnapshot" do
    test "roundtrip with temperature only" do
      region =
        FieldRegion.new(%{
          region_id: 42,
          chunk_coord: {1, 2, -3},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          field_types: [:temperature]
        })

      temp_layer =
        region
        |> FieldRegion.get_layer(:temperature)
        |> FieldLayer.put(Types.macro_index!({0, 0, 0}), 100.0)
        |> FieldLayer.put(Types.macro_index!({1, 0, 0}), 50.0)

      region = FieldRegion.put_layer(region, :temperature, temp_layer)
      region = %{region | tick_count: 7}

      payload = FieldCodec.encode_snapshot_payload(region, 0xBADC_0FFE_F00D_BEEF)
      decoded = FieldCodec.decode_snapshot_payload!(payload)

      assert decoded.opcode == FieldCodec.opcode_snapshot()
      assert decoded.logical_scene_id == 0xBADC_0FFE_F00D_BEEF
      assert decoded.chunk_coord == {1, 2, -3}
      assert decoded.region_id == 42
      assert decoded.tick_count == 7
      assert decoded.field_mask == FieldCodec.field_mask_temperature()
      assert decoded.cell_count == 2

      assert decoded.macro_indices == Enum.sort(decoded.macro_indices)
      assert Types.macro_index!({0, 0, 0}) in decoded.macro_indices
      assert Types.macro_index!({1, 0, 0}) in decoded.macro_indices

      assert length(decoded.temperature_values) == decoded.cell_count
      assert decoded.electric_values == []
      assert decoded.ionization_values == []
    end

    test "roundtrip with all three field types" do
      region =
        FieldRegion.new(%{
          region_id: 99,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          field_types: [:temperature, :electric_potential, :ionization]
        })

      idx_a = Types.macro_index!({0, 0, 0})
      idx_b = Types.macro_index!({2, 0, 0})

      temp =
        region
        |> FieldRegion.get_layer(:temperature)
        |> FieldLayer.put(idx_a, 80.0)

      elec =
        region
        |> FieldRegion.get_layer(:electric_potential)
        |> FieldLayer.put(idx_b, 120.0)

      ion =
        region
        |> FieldRegion.get_layer(:ionization)
        |> FieldLayer.put(idx_a, 200.0)

      region =
        region
        |> FieldRegion.put_layer(:temperature, temp)
        |> FieldRegion.put_layer(:electric_potential, elec)
        |> FieldRegion.put_layer(:ionization, ion)

      payload = FieldCodec.encode_snapshot_payload(region, 1)
      decoded = FieldCodec.decode_snapshot_payload!(payload)

      assert decoded.field_mask ==
               FieldCodec.field_mask_temperature() +
                 FieldCodec.field_mask_electric_potential() +
                 FieldCodec.field_mask_ionization()

      # Union of all field-type indices, sorted ascending.
      assert decoded.macro_indices == Enum.sort([idx_a, idx_b])
      assert decoded.cell_count == 2

      # All three value arrays have the same length as macro_indices.
      assert length(decoded.temperature_values) == decoded.cell_count
      assert length(decoded.electric_values) == decoded.cell_count
      assert length(decoded.ionization_values) == decoded.cell_count

      # Look up specific values by their index position.
      pos_a = Enum.find_index(decoded.macro_indices, &(&1 == idx_a))
      pos_b = Enum.find_index(decoded.macro_indices, &(&1 == idx_b))

      assert_in_delta Enum.at(decoded.temperature_values, pos_a), 80.0, 0.001
      assert_in_delta Enum.at(decoded.electric_values, pos_b), 120.0, 0.001
      # ionization is rounded to u8 (clamped to 255 max).
      assert Enum.at(decoded.ionization_values, pos_a) == 200
    end

    test "cell_count matches macro_indices length" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          field_types: [:temperature]
        })

      payload = FieldCodec.encode_snapshot_payload(region, 0)
      decoded = FieldCodec.decode_snapshot_payload!(payload)

      assert decoded.cell_count == length(decoded.macro_indices)
      assert decoded.cell_count == 0
    end

    test "ionization values are clamped to u8 range [0,255]" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {1, 1, 1}},
          field_types: [:ionization]
        })

      ion =
        region
        |> FieldRegion.get_layer(:ionization)
        |> FieldLayer.put(0, 1000.0)
        |> FieldLayer.put(1, -50.0)

      region = FieldRegion.put_layer(region, :ionization, ion)

      payload = FieldCodec.encode_snapshot_payload(region, 0)
      decoded = FieldCodec.decode_snapshot_payload!(payload)

      Enum.each(decoded.ionization_values, fn v ->
        assert v in 0..255
      end)
    end
  end

  describe "0x74 FieldRegionDestroyed" do
    test "roundtrip with default :expired reason" do
      payload = FieldCodec.encode_destroyed_payload(7, {1, 2, 3}, 0x42)
      decoded = FieldCodec.decode_destroyed_payload!(payload)

      assert decoded.opcode == FieldCodec.opcode_destroyed()
      assert decoded.logical_scene_id == 0x42
      assert decoded.chunk_coord == {1, 2, 3}
      assert decoded.region_id == 7
      assert decoded.destroy_reason == :expired
    end

    test "roundtrip across all destroy_reason variants" do
      for reason <- [:expired, :lease_revoked, :explicit, :chunk_crash] do
        payload = FieldCodec.encode_destroyed_payload(1, {0, 0, 0}, 0, reason)
        decoded = FieldCodec.decode_destroyed_payload!(payload)
        assert decoded.destroy_reason == reason
      end
    end

    test "unknown reason byte decodes to :unknown" do
      # Manually construct payload with reason byte 0xFF.
      payload =
        <<FieldCodec.opcode_destroyed()::8, 0::64, 0::32, 0::32, 0::32, 0::64, 0xFF::8>>

      decoded = FieldCodec.decode_destroyed_payload!(payload)
      assert decoded.destroy_reason == :unknown
    end
  end
end
