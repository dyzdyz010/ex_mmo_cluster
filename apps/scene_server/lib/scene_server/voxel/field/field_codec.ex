defmodule SceneServer.Voxel.Field.FieldCodec do
  @moduledoc """
  Phase 6 局部场最小目标:wire codec for

    * opcode `0x73` `FieldRegionSnapshot`(S→C)
    * opcode `0x74` `FieldRegionDestroyed`(S→C)

  Wire 字节序统一:数值字段大端,floats(temperature / electric_potential / electric_current /
  smoke_density / oxygen) little-endian f32(与 FieldLayer 存储一致)。Payload **包含** opcode byte:
  下游 transport(tcp_connection)直接写 socket;`{packet, 4}` 在
  gen_tcp 层补 4 字节长度前缀。

  FieldRegionSnapshot 结构:

      u8   opcode = 0x73
      u64  logical_scene_id   (big)
      i32  chunk_x            (big)
      i32  chunk_y            (big)
      i32  chunk_z            (big)
      u64  region_id          (big)
      u32  tick_count         (big)
      u8   field_mask         (bit0 = temperature, bit1 = electric_potential, bit2 = ionization, bit3 = electric_current, bit4 = smoke_density, bit5 = oxygen)
      u16  cell_count         (big)
      [u16; cell_count] macro_indices              (big endian)
      [f32 le; cell_count] temperature_values      (iff bit0 set)
      [f32 le; cell_count] electric_potential_values (iff bit1 set)
      [f32 le; cell_count] electric_current_values (iff bit3 set)
      [u8;    cell_count] ionization_values        (iff bit2 set)
      [f32 le; cell_count] smoke_density_values    (iff bit4 set)
      [f32 le; cell_count] oxygen_values           (iff bit5 set)

  FieldRegionDestroyed 结构:

      u8   opcode = 0x74
      u64  logical_scene_id
      i32  chunk_x
      i32  chunk_y
      i32  chunk_z
      u64  region_id
      u8   destroy_reason
  """

  import Bitwise

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion}

  @opcode_snapshot 0x73
  @opcode_destroyed 0x74

  @field_mask_temperature 0x01
  @field_mask_electric_potential 0x02
  @field_mask_ionization 0x04
  @field_mask_electric_current 0x08
  @field_mask_smoke_density 0x10
  @field_mask_oxygen 0x20

  @destroy_reason_expired 0x00
  @destroy_reason_lease_revoked 0x01
  @destroy_reason_explicit 0x02
  @destroy_reason_chunk_crash 0x03

  @doc "Returns the wire opcode for FieldRegionSnapshot."
  def opcode_snapshot, do: @opcode_snapshot

  @doc "Returns the wire opcode for FieldRegionDestroyed."
  def opcode_destroyed, do: @opcode_destroyed

  @doc "Bit positions for the field_mask byte."
  def field_mask_temperature, do: @field_mask_temperature
  def field_mask_electric_potential, do: @field_mask_electric_potential
  def field_mask_ionization, do: @field_mask_ionization
  def field_mask_electric_current, do: @field_mask_electric_current
  def field_mask_smoke_density, do: @field_mask_smoke_density
  def field_mask_oxygen, do: @field_mask_oxygen

  # ---- FieldRegionSnapshot (0x73) -------------------------------------------

  @doc """
  Encodes a FieldRegion as the wire payload for opcode `0x73`. The encoded
  binary already includes the opcode byte.
  """
  @spec encode_snapshot_payload(FieldRegion.t(), non_neg_integer()) :: binary()
  def encode_snapshot_payload(%FieldRegion{} = region, logical_scene_id)
      when is_integer(logical_scene_id) and logical_scene_id >= 0 do
    {cx, cy, cz} = region.chunk_coord
    field_mask = compute_field_mask(region.field_types)

    temperature_cells =
      if has_mask?(field_mask, @field_mask_temperature) do
        collect_cells(region, :temperature)
      else
        []
      end

    electric_cells =
      if has_mask?(field_mask, @field_mask_electric_potential) do
        collect_cells(region, :electric_potential)
      else
        []
      end

    current_cells =
      if has_mask?(field_mask, @field_mask_electric_current) do
        collect_cells(region, :electric_current)
      else
        []
      end

    ionization_cells =
      if has_mask?(field_mask, @field_mask_ionization) do
        collect_cells(region, :ionization)
      else
        []
      end

    smoke_cells =
      if has_mask?(field_mask, @field_mask_smoke_density) do
        collect_cells(region, :smoke_density)
      else
        []
      end

    oxygen_cells =
      if has_mask?(field_mask, @field_mask_oxygen) do
        collect_cells(region, :oxygen)
      else
        []
      end

    all_indices =
      (Enum.map(temperature_cells, &elem(&1, 0)) ++
         Enum.map(electric_cells, &elem(&1, 0)) ++
         Enum.map(current_cells, &elem(&1, 0)) ++
         Enum.map(ionization_cells, &elem(&1, 0)) ++
         Enum.map(smoke_cells, &elem(&1, 0)) ++
         Enum.map(oxygen_cells, &elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort()

    cell_count = length(all_indices)
    temp_map = Map.new(temperature_cells)
    elec_map = Map.new(electric_cells)
    current_map = Map.new(current_cells)
    ion_map = Map.new(ionization_cells)
    smoke_map = Map.new(smoke_cells)
    oxygen_map = Map.new(oxygen_cells)

    temp_layer =
      if has_mask?(field_mask, @field_mask_temperature),
        do: FieldRegion.get_layer(region, :temperature)

    elec_layer =
      if has_mask?(field_mask, @field_mask_electric_potential),
        do: FieldRegion.get_layer(region, :electric_potential)

    current_layer =
      if has_mask?(field_mask, @field_mask_electric_current),
        do: FieldRegion.get_layer(region, :electric_current)

    ion_layer =
      if has_mask?(field_mask, @field_mask_ionization),
        do: FieldRegion.get_layer(region, :ionization)

    smoke_layer =
      if has_mask?(field_mask, @field_mask_smoke_density),
        do: FieldRegion.get_layer(region, :smoke_density)

    oxygen_layer =
      if has_mask?(field_mask, @field_mask_oxygen),
        do: FieldRegion.get_layer(region, :oxygen)

    indices_bin =
      Enum.reduce(all_indices, <<>>, fn idx, acc ->
        <<acc::binary, idx::unsigned-big-integer-size(16)>>
      end)

    temp_bin =
      if has_mask?(field_mask, @field_mask_temperature) do
        Enum.reduce(all_indices, <<>>, fn idx, acc ->
          val = Map.get(temp_map, idx, FieldLayer.get(temp_layer, idx))
          <<acc::binary, val::float-32-little>>
        end)
      else
        <<>>
      end

    elec_bin =
      if has_mask?(field_mask, @field_mask_electric_potential) do
        Enum.reduce(all_indices, <<>>, fn idx, acc ->
          val = Map.get(elec_map, idx, FieldLayer.get(elec_layer, idx))
          <<acc::binary, val::float-32-little>>
        end)
      else
        <<>>
      end

    current_bin =
      if has_mask?(field_mask, @field_mask_electric_current) do
        Enum.reduce(all_indices, <<>>, fn idx, acc ->
          val = Map.get(current_map, idx, FieldLayer.get(current_layer, idx))
          <<acc::binary, val::float-32-little>>
        end)
      else
        <<>>
      end

    ion_bin =
      if has_mask?(field_mask, @field_mask_ionization) do
        Enum.reduce(all_indices, <<>>, fn idx, acc ->
          raw = Map.get(ion_map, idx, FieldLayer.get(ion_layer, idx))
          byte = raw |> round() |> max(0) |> min(255)
          <<acc::binary, byte::unsigned-big-integer-size(8)>>
        end)
      else
        <<>>
      end

    smoke_bin =
      if has_mask?(field_mask, @field_mask_smoke_density) do
        Enum.reduce(all_indices, <<>>, fn idx, acc ->
          val = Map.get(smoke_map, idx, FieldLayer.get(smoke_layer, idx))
          <<acc::binary, val::float-32-little>>
        end)
      else
        <<>>
      end

    oxygen_bin =
      if has_mask?(field_mask, @field_mask_oxygen) do
        Enum.reduce(all_indices, <<>>, fn idx, acc ->
          val = Map.get(oxygen_map, idx, FieldLayer.get(oxygen_layer, idx))
          <<acc::binary, val::float-32-little>>
        end)
      else
        <<>>
      end

    <<@opcode_snapshot::unsigned-big-integer-size(8),
      logical_scene_id::unsigned-big-integer-size(64), cx::signed-big-integer-size(32),
      cy::signed-big-integer-size(32), cz::signed-big-integer-size(32),
      region.region_id::unsigned-big-integer-size(64),
      region.tick_count::unsigned-big-integer-size(32), field_mask::unsigned-big-integer-size(8),
      cell_count::unsigned-big-integer-size(16), indices_bin::binary, temp_bin::binary,
      elec_bin::binary, current_bin::binary, ion_bin::binary, smoke_bin::binary,
      oxygen_bin::binary>>
  end

  @doc """
  Decodes a 0x73 FieldRegionSnapshot payload (including opcode byte). Returns
  a map with all parsed fields. Raises on malformed input.
  """
  @spec decode_snapshot_payload!(binary()) :: map()
  def decode_snapshot_payload!(<<
        @opcode_snapshot::unsigned-big-integer-size(8),
        logical_scene_id::unsigned-big-integer-size(64),
        cx::signed-big-integer-size(32),
        cy::signed-big-integer-size(32),
        cz::signed-big-integer-size(32),
        region_id::unsigned-big-integer-size(64),
        tick_count::unsigned-big-integer-size(32),
        field_mask::unsigned-big-integer-size(8),
        cell_count::unsigned-big-integer-size(16),
        rest::binary
      >>) do
    indices_size = cell_count * 2
    <<indices_bin::binary-size(^indices_size), rest2::binary>> = rest
    macro_indices = for <<idx::unsigned-big-integer-size(16) <- indices_bin>>, do: idx

    {temperature_values, rest3} =
      if has_mask?(field_mask, @field_mask_temperature) do
        temp_size = cell_count * 4
        <<temp_bin::binary-size(^temp_size), r::binary>> = rest2
        vals = for <<v::float-32-little <- temp_bin>>, do: v
        {vals, r}
      else
        {[], rest2}
      end

    {electric_values, rest4} =
      if has_mask?(field_mask, @field_mask_electric_potential) do
        elec_size = cell_count * 4
        <<elec_bin::binary-size(^elec_size), r::binary>> = rest3
        vals = for <<v::float-32-little <- elec_bin>>, do: v
        {vals, r}
      else
        {[], rest3}
      end

    {electric_current_values, rest5} =
      if has_mask?(field_mask, @field_mask_electric_current) do
        current_size = cell_count * 4
        <<current_bin::binary-size(^current_size), r::binary>> = rest4
        vals = for <<v::float-32-little <- current_bin>>, do: v
        {vals, r}
      else
        {[], rest4}
      end

    {ionization_values, rest6} =
      if has_mask?(field_mask, @field_mask_ionization) do
        ion_size = cell_count
        <<ion_bin::binary-size(^ion_size), r::binary>> = rest5
        vals = for <<v::unsigned-big-integer-size(8) <- ion_bin>>, do: v
        {vals, r}
      else
        {[], rest5}
      end

    {smoke_density_values, rest7} =
      if has_mask?(field_mask, @field_mask_smoke_density) do
        smoke_size = cell_count * 4
        <<smoke_bin::binary-size(^smoke_size), r::binary>> = rest6
        vals = for <<v::float-32-little <- smoke_bin>>, do: v
        {vals, r}
      else
        {[], rest6}
      end

    {oxygen_values, _rest8} =
      if has_mask?(field_mask, @field_mask_oxygen) do
        oxygen_size = cell_count * 4
        <<oxygen_bin::binary-size(^oxygen_size), r::binary>> = rest7
        vals = for <<v::float-32-little <- oxygen_bin>>, do: v
        {vals, r}
      else
        {[], rest7}
      end

    %{
      opcode: @opcode_snapshot,
      logical_scene_id: logical_scene_id,
      chunk_coord: {cx, cy, cz},
      region_id: region_id,
      tick_count: tick_count,
      field_mask: field_mask,
      cell_count: cell_count,
      macro_indices: macro_indices,
      temperature_values: temperature_values,
      electric_values: electric_values,
      electric_current_values: electric_current_values,
      ionization_values: ionization_values,
      smoke_density_values: smoke_density_values,
      oxygen_values: oxygen_values
    }
  end

  # ---- FieldRegionDestroyed (0x74) ------------------------------------------

  @doc """
  Encodes a FieldRegionDestroyed payload (opcode 0x74, including opcode byte).
  """
  @spec encode_destroyed_payload(
          non_neg_integer(),
          {integer(), integer(), integer()},
          non_neg_integer(),
          atom()
        ) :: binary()
  def encode_destroyed_payload(
        region_id,
        chunk_coord,
        logical_scene_id,
        destroy_reason \\ :expired
      ) do
    {cx, cy, cz} = chunk_coord
    reason_byte = encode_destroy_reason(destroy_reason)

    <<@opcode_destroyed::unsigned-big-integer-size(8),
      logical_scene_id::unsigned-big-integer-size(64), cx::signed-big-integer-size(32),
      cy::signed-big-integer-size(32), cz::signed-big-integer-size(32),
      region_id::unsigned-big-integer-size(64), reason_byte::unsigned-big-integer-size(8)>>
  end

  @doc "Decodes a 0x74 FieldRegionDestroyed payload (including opcode byte)."
  @spec decode_destroyed_payload!(binary()) :: map()
  def decode_destroyed_payload!(<<
        @opcode_destroyed::unsigned-big-integer-size(8),
        logical_scene_id::unsigned-big-integer-size(64),
        cx::signed-big-integer-size(32),
        cy::signed-big-integer-size(32),
        cz::signed-big-integer-size(32),
        region_id::unsigned-big-integer-size(64),
        reason_byte::unsigned-big-integer-size(8)
      >>) do
    %{
      opcode: @opcode_destroyed,
      logical_scene_id: logical_scene_id,
      chunk_coord: {cx, cy, cz},
      region_id: region_id,
      destroy_reason: decode_destroy_reason(reason_byte)
    }
  end

  # ---- helpers --------------------------------------------------------------

  defp has_mask?(mask, bit), do: band(mask, bit) != 0

  defp compute_field_mask(field_types) do
    Enum.reduce(field_types, 0, fn
      :temperature, acc -> bor(acc, @field_mask_temperature)
      :electric_potential, acc -> bor(acc, @field_mask_electric_potential)
      :electric_current, acc -> bor(acc, @field_mask_electric_current)
      :ionization, acc -> bor(acc, @field_mask_ionization)
      :smoke_density, acc -> bor(acc, @field_mask_smoke_density)
      :oxygen, acc -> bor(acc, @field_mask_oxygen)
      _, acc -> acc
    end)
  end

  defp collect_cells(region, field_type) do
    layer = FieldRegion.get_layer(region, field_type)
    FieldLayer.active_cells(layer, region.aabb)
  end

  defp encode_destroy_reason(:expired), do: @destroy_reason_expired
  defp encode_destroy_reason(:lease_revoked), do: @destroy_reason_lease_revoked
  defp encode_destroy_reason(:explicit), do: @destroy_reason_explicit
  defp encode_destroy_reason(:chunk_crash), do: @destroy_reason_chunk_crash
  defp encode_destroy_reason(_), do: @destroy_reason_explicit

  defp decode_destroy_reason(@destroy_reason_expired), do: :expired
  defp decode_destroy_reason(@destroy_reason_lease_revoked), do: :lease_revoked
  defp decode_destroy_reason(@destroy_reason_explicit), do: :explicit
  defp decode_destroy_reason(@destroy_reason_chunk_crash), do: :chunk_crash
  defp decode_destroy_reason(_), do: :unknown
end
