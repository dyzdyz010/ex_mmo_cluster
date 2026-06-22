defmodule SceneServer.Voxel.Field.FieldCodecTest do
  # Phase 6 局部场最小目标:0x73 FieldRegionSnapshot / 0x74 FieldRegionDestroyed
  # wire codec roundtrip 测试。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldCodec, FieldLayer, FieldRegion}

  alias SceneServer.Voxel.Field.Kernels.{
    CircuitCurrentKernel,
    ElectricPotentialKernel,
    LightPropagationKernel,
    TemperatureDiffusionKernel
  }

  alias SceneServer.Voxel.Types

  describe "0x73 FieldRegionSnapshot" do
    test "reserves a first-class electric current field mask" do
      assert FieldCodec.field_mask_electric_current() == 0x08
    end

    test "reserves a first-class light field mask" do
      assert FieldCodec.field_mask_light() == 0x10
    end

    test "roundtrip with light as a first-class layer (u8 0..255)" do
      idx_a = Types.macro_index!({0, 0, 0})
      idx_b = Types.macro_index!({2, 0, 0})

      region =
        FieldRegion.new(%{
          region_id: 88,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {2, 0, 0}},
          kernels: [%{id: :light_propagation, module: LightPropagationKernel}]
        })

      light =
        region
        |> FieldRegion.get_layer(:light)
        |> FieldLayer.put(idx_a, 255.0)
        # 300 截断到 255。
        |> FieldLayer.put(idx_b, 300.0)

      region = FieldRegion.put_layer(region, :light, light)

      decoded =
        region |> FieldCodec.encode_snapshot_payload(1) |> FieldCodec.decode_snapshot_payload!()

      # 光 kernel 声明 [:light, :light_color] → region 同时携两层(mask 0x30)。
      assert decoded.field_mask ==
               FieldCodec.field_mask_light() + FieldCodec.field_mask_light_color()

      assert decoded.macro_indices == [idx_a, idx_b]
      assert length(decoded.light_values) == decoded.cell_count
      # u8 clamp [0,255]。
      assert Enum.at(decoded.light_values, 0) == 255
      assert Enum.at(decoded.light_values, 1) == 255
      # 未设颜色 → 默认 0(黑)packed。
      assert decoded.light_color_values == [0, 0]
    end

    test "reserves a first-class light_color field mask" do
      assert FieldCodec.field_mask_light_color() == 0x20
    end

    test "roundtrip with light + light_color (3 u8 RGB packed)" do
      idx_a = Types.macro_index!({0, 0, 0})
      idx_b = Types.macro_index!({2, 0, 0})

      region =
        FieldRegion.new(%{
          region_id: 91,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {2, 0, 0}},
          kernels: [%{id: :light_propagation, module: LightPropagationKernel}]
        })

      light =
        region
        |> FieldRegion.get_layer(:light)
        |> FieldLayer.put(idx_a, 255.0)
        |> FieldLayer.put(idx_b, 128.0)

      # packed RGB888 存为 float(≤2^24 精确)。warm 0xFFA040, cool 0x60A0FF。
      color =
        region
        |> FieldRegion.get_layer(:light_color)
        |> FieldLayer.put(idx_a, 0xFFA040 * 1.0)
        |> FieldLayer.put(idx_b, 0x60A0FF * 1.0)

      region =
        region
        |> FieldRegion.put_layer(:light, light)
        |> FieldRegion.put_layer(:light_color, color)

      decoded =
        region |> FieldCodec.encode_snapshot_payload(1) |> FieldCodec.decode_snapshot_payload!()

      assert decoded.field_mask ==
               FieldCodec.field_mask_light() + FieldCodec.field_mask_light_color()

      # 3 u8 RGB 解回 packed RGB888,逐字节还原源色。
      assert decoded.light_color_values == [0xFFA040, 0x60A0FF]
    end

    test "roundtrip with electric current as a first-class layer" do
      idx = Types.macro_index!({1, 0, 0})

      region =
        FieldRegion.new(%{
          region_id: 77,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {2, 0, 0}},
          kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
          source_points: [%{macro_index: 0, field_type: :electric_potential, value: 120.0}]
        })

      current =
        region
        |> FieldRegion.get_layer(:electric_current)
        |> FieldLayer.put(idx, 4.5)

      region = FieldRegion.put_layer(region, :electric_current, current)

      decoded =
        region |> FieldCodec.encode_snapshot_payload(1) |> FieldCodec.decode_snapshot_payload!()

      assert decoded.field_mask ==
               FieldCodec.field_mask_electric_potential() +
                 FieldCodec.field_mask_ionization() +
                 FieldCodec.field_mask_electric_current()

      assert decoded.macro_indices == [idx]
      assert decoded.electric_values == [0.0]
      assert_in_delta hd(decoded.electric_current_values), 4.5, 0.001
      assert decoded.ionization_values == [0]
    end

    test "roundtrip with temperature only" do
      region =
        FieldRegion.new(%{
          region_id: 42,
          chunk_coord: {1, 2, -3},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}]
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
          kernels: [
            %{id: :temperature_diffusion, module: TemperatureDiffusionKernel},
            %{id: :electric_potential, module: ElectricPotentialKernel}
          ]
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
      assert_in_delta Enum.at(decoded.temperature_values, pos_b), 20.0, 0.001
      assert_in_delta Enum.at(decoded.electric_values, pos_a), 0.0, 0.001
      assert_in_delta Enum.at(decoded.electric_values, pos_b), 120.0, 0.001
      # ionization is rounded to u8 (clamped to 255 max).
      assert Enum.at(decoded.ionization_values, pos_a) == 200
      assert Enum.at(decoded.ionization_values, pos_b) == 0
    end

    test "cell_count matches macro_indices length" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}]
        })

      payload = FieldCodec.encode_snapshot_payload(region, 0)
      decoded = FieldCodec.decode_snapshot_payload!(payload)

      assert decoded.cell_count == length(decoded.macro_indices)
      assert decoded.cell_count == 0
    end

    test "temperature baseline cells are not encoded" do
      idx = Types.macro_index!({0, 0, 0})

      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {3, 3, 3}},
          kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}]
        })

      temp_layer =
        region
        |> FieldRegion.get_layer(:temperature)
        |> FieldLayer.put(idx, 20.0)

      region = FieldRegion.put_layer(region, :temperature, temp_layer)

      decoded =
        region |> FieldCodec.encode_snapshot_payload(0) |> FieldCodec.decode_snapshot_payload!()

      assert decoded.cell_count == 0

      temp_layer = FieldLayer.put(temp_layer, idx, 100.0)
      region = FieldRegion.put_layer(region, :temperature, temp_layer)

      decoded =
        region |> FieldCodec.encode_snapshot_payload(0) |> FieldCodec.decode_snapshot_payload!()

      assert decoded.cell_count == 1
      assert decoded.macro_indices == [idx]
      assert decoded.temperature_values == [100.0]
    end

    test "ionization values are clamped to u8 range [0,255]" do
      region =
        FieldRegion.new(%{
          region_id: 1,
          chunk_coord: {0, 0, 0},
          aabb: {{0, 0, 0}, {1, 1, 1}},
          kernels: [%{id: :electric_potential, module: ElectricPotentialKernel}]
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
