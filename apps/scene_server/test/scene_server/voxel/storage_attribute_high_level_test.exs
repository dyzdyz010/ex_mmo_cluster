defmodule SceneServer.Voxel.StorageAttributeHighLevelTest do
  # Phase 5.C: Storage.put_attribute_for_cell 高层 API。
  #
  # 因为该 API 默认通过 module-named singleton `SceneServer.Voxel.AttributeCatalog`
  # 反查 attribute name → id，本测试 setup 启动 production catalog（默认名 +
  # 默认 seed），整 file async: false（singleton 跨测试共享）。
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.AttributeSet
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

  setup do
    # 启 production-named AttributeCatalog（默认 `SceneServer.Voxel.AttributeCatalog`
    # 即 `__MODULE__`），自动加载默认 priv seed。
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end

    :ok
  end

  # 25.0 °C in Q16.16
  @temperature_25 1_638_400
  # 30.0 °C in Q16.16
  @temperature_30 1_966_080

  defp solid_chunk(macro_index, material_id \\ 1) do
    storage = Storage.new(0, {0, 0, 0})
    Storage.put_solid_block(storage, macro_index, NormalBlockData.new(material_id))
  end

  describe "put_attribute_for_cell on solid cell" do
    test "writes a new attribute_set when cell has no attribute_set yet" do
      storage = solid_chunk(0)

      updated =
        Storage.put_attribute_for_cell(storage, 0, "temperature", @temperature_25)

      header = Enum.at(updated.macro_headers, 0)
      assert header.mode == MacroCellHeader.cell_mode_solid_block()

      block = Enum.at(updated.normal_blocks, header.payload_index)
      assert block.attribute_set_ref != 0
      assert block.material_id == 1

      # attribute_sets pool 应含至少一条 AttributeSet
      assert length(updated.attribute_sets) >= 1
      set = Enum.at(updated.attribute_sets, block.attribute_set_ref - 1)
      assert %AttributeSet{} = set
      assert length(set.entries) == 1

      [entry] = set.entries
      # temperature id
      assert entry.key_id == 1
      # fixed32 tag
      assert entry.value_type == 0x03
      assert entry.value == @temperature_25
    end

    test "re-puts of same attribute & value yield same ref (intern dedup)" do
      storage = solid_chunk(0)
      a = Storage.put_attribute_for_cell(storage, 0, "temperature", @temperature_25)
      header = Enum.at(a.macro_headers, 0)
      block_a = Enum.at(a.normal_blocks, header.payload_index)
      ref_a = block_a.attribute_set_ref

      # 第二次 put 同 cell 同 name 同 value：set 结构等价 → intern 返回同 ref
      b = Storage.put_attribute_for_cell(a, 0, "temperature", @temperature_25)
      header_b = Enum.at(b.macro_headers, 0)
      block_b = Enum.at(b.normal_blocks, header_b.payload_index)

      assert block_b.attribute_set_ref == ref_a
      # 池不增长
      assert length(b.attribute_sets) == length(a.attribute_sets)
    end

    test "updating attribute value on same cell replaces the entry (override semantics)" do
      storage = solid_chunk(0)
      a = Storage.put_attribute_for_cell(storage, 0, "temperature", @temperature_25)
      b = Storage.put_attribute_for_cell(a, 0, "temperature", @temperature_30)

      header = Enum.at(b.macro_headers, 0)
      block = Enum.at(b.normal_blocks, header.payload_index)
      set = Enum.at(b.attribute_sets, block.attribute_set_ref - 1)

      assert length(set.entries) == 1
      [entry] = set.entries
      # temperature
      assert entry.key_id == 1
      assert entry.value == @temperature_30
    end

    test "writing a different attribute name preserves prior entries" do
      storage = solid_chunk(0)
      a = Storage.put_attribute_for_cell(storage, 0, "temperature", @temperature_25)
      # 50.0% humidity
      b = Storage.put_attribute_for_cell(a, 0, "humidity", 3_276_800)

      header = Enum.at(b.macro_headers, 0)
      block = Enum.at(b.normal_blocks, header.payload_index)
      set = Enum.at(b.attribute_sets, block.attribute_set_ref - 1)

      assert length(set.entries) == 2

      entries_by_key = Map.new(set.entries, fn e -> {e.key_id, e} end)
      assert entries_by_key[1].value == @temperature_25
      assert entries_by_key[2].value == 3_276_800
    end
  end

  describe "put_attribute_for_cell value range validation" do
    test "raises when value exceeds max_value" do
      storage = solid_chunk(0)
      # temperature max = 327_680_000
      assert_raise ArgumentError, ~r/out of range/, fn ->
        Storage.put_attribute_for_cell(storage, 0, "temperature", 327_680_001)
      end
    end

    test "raises when value below min_value" do
      storage = solid_chunk(0)
      # temperature min = -17_904_824
      assert_raise ArgumentError, ~r/out of range/, fn ->
        Storage.put_attribute_for_cell(storage, 0, "temperature", -17_904_825)
      end
    end

    test "accepts boundary min_value" do
      storage = solid_chunk(0)
      # temperature min = -17_904_824
      updated = Storage.put_attribute_for_cell(storage, 0, "temperature", -17_904_824)
      header = Enum.at(updated.macro_headers, 0)
      block = Enum.at(updated.normal_blocks, header.payload_index)
      assert block.attribute_set_ref != 0
    end

    test "accepts boundary max_value" do
      storage = solid_chunk(0)
      updated = Storage.put_attribute_for_cell(storage, 0, "temperature", 327_680_000)
      header = Enum.at(updated.macro_headers, 0)
      block = Enum.at(updated.normal_blocks, header.payload_index)
      assert block.attribute_set_ref != 0
    end
  end

  describe "put_attribute_for_cell catalog miss" do
    test "raises when attribute name not in catalog" do
      storage = solid_chunk(0)

      assert_raise ArgumentError, ~r/not in catalog/, fn ->
        Storage.put_attribute_for_cell(storage, 0, "nonexistent", 0)
      end
    end
  end

  describe "put_attribute_for_cell on non-solid cell (Phase 5.C option 1)" do
    test "raises on empty cell" do
      # Phase 5.C 选项 1：要求 caller 先 put_solid_block，不自动转换
      storage = Storage.new(0, {0, 0, 0})

      assert_raise ArgumentError, ~r/:empty mode/, fn ->
        Storage.put_attribute_for_cell(storage, 0, "temperature", @temperature_25)
      end
    end

    test "raises on refined cell" do
      storage = Storage.new(0, {0, 0, 0})

      refined =
        Storage.put_micro_block(storage, 0, 0, %{material_id: 1, health: 100})

      assert_raise ArgumentError, ~r/:refined mode/, fn ->
        Storage.put_attribute_for_cell(refined, 0, "temperature", @temperature_25)
      end
    end
  end
end
