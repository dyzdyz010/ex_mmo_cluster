defmodule VoxelRegion.LogProjectionTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.LogProjection
  alias MmoContracts.Voxel.Codec

  # Test-only: pure committed-log projection. World commit/reload integration lives in damage_world_test.
  test "live full frame is scoped including empty clear; historical regions never activate transient flow" do
    txn = %{seq: 8, entries: [], coarse: [], liquid_falls: %{material: 21, transfers: [{{-1,2,3},1},{{200,2,3},524288}]}}
    projected = VoxelRegion.PropertyObservation.project(txn, {{-1,0,0},{0,1,1}})
    assert projected.liquid_falls.transfers == [{{-1,2,3},1}]
    assert VoxelRegion.PropertyObservation.project(txn, {{0,0,0},{1,1,1}}).liquid_falls.transfers == []
    assert {:voxel_log_transaction_payload, bytes} = LogProjection.message(txn, {{{-1,0,0},{-1,0,0}}, 5})
    assert {:ok, %{liquid_falls: %{transfers: [{{-1,2,3},1}]}}} = Codec.decode_transaction(bytes)
    clear = %{txn | liquid_falls: %{material: 21, transfers: []}}
    assert {:voxel_log_transaction_payload, bytes} = LogProjection.message(clear, {{{0,0,0},{0,0,0}}, 5})
    assert {:ok, %{liquid_falls: %{material: 21, transfers: []}}} = Codec.decode_transaction(bytes)
    refute Map.has_key?(LogProjection.region(txn, 0, {-1,0,0}), :liquid_falls)
  end

  test "negative corner edits reach every adjacent ring, in sequence order after the cursor" do
    older = %{seq: 2, entries: [%{coord: {-64, -64, -64}, material: 11}], coarse: []}
    newer = %{seq: 9, entries: [%{coord: {-64, -64, -64}, material: 19}], coarse: []}
    unrelated = %{seq: 7, entries: [%{coord: {257, 1, 2}, material: 11}], coarse: []}
    index = Enum.reduce([newer, unrelated, older], %{}, &LogProjection.index(&2, &1))
    entries = Map.new([older, newer, unrelated], &{&1.seq, &1})

    for x <- -2..-1, y <- -2..-1, z <- -2..-1 do
      assert LogProjection.since(index, entries, 0, {x, y, z}, 0) == [older, newer]
      assert LogProjection.since(index, entries, 0, {x, y, z}, 2) == [newer]
      assert LogProjection.since(index, entries, 0, {x, y, z}, 9) == []
    end

    assert LogProjection.since(index, entries, 0, {0, -1, -1}, 0) == []
    assert LogProjection.since(index, entries, 1, {-1, -1, -1}, 0) == []
  end

  test "coarse changes and structural replacement retain their own level and ring" do
    coarse = %{level: 3, cell: {64, 2, 2}, material: 19}
    txn = %{seq: 1, entries: [], coarse: [coarse]}
    replacement = %{seq: 2, entries: [%{structure: :removed, level: 4, cell: {64, 2, 2}}], coarse: []}
    index = %{} |> LogProjection.index(txn) |> LogProjection.index(replacement)
    entries = %{1 => txn, 2 => replacement}
    for x <- 0..1 do
      assert LogProjection.since(index, entries, 3, {x, 0, 0}, 0) == [txn]
      assert LogProjection.since(index, entries, 4, {x, 0, 0}, 0) == :region
    end
    assert LogProjection.since(index, entries, 0, {0, 0, 0}, 0) == []
    assert LogProjection.since(index, entries, 4, {2, 0, 0}, 0) == []
  end

  test "payload replacement reaches all 26 neighbors and stops projection at its cursor" do
    bytes = Codec.encode_payload(2, {-1, 0, 1}, 5, 123, <<>>) |> IO.iodata_to_binary()
    txn = %{seq: 5, entries: [%{payload: bytes}], coarse: []}
    index = LogProjection.index(%{}, txn)
    for x <- -2..0, y <- -1..1, z <- 0..2 do
      assert LogProjection.since(index, %{5 => txn}, 2, {x, y, z}, 4) == :region
      assert LogProjection.since(index, %{5 => txn}, 2, {x, y, z}, 5) == []
    end
    assert LogProjection.since(index, %{5 => txn}, 2, {1, 0, 1}, 0) == []
    assert LogProjection.since(index, %{5 => txn}, 1, {-1, 0, 1}, 0) == []
  end
end
