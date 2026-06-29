defmodule MmoContracts.WorldPackShardTest do
  use ExUnit.Case, async: true

  alias MmoContracts.WorldPackShard

  defp temp_path do
    Path.join(System.tmp_dir!(), "world_pack_shard_#{System.unique_integer([:positive])}.vxpack")
  end

  test "encodes chunk payloads with a footer offset table" do
    assert {:ok, shard} =
             WorldPackShard.encode([
               %{local_coord: {13, 0, 13}, payload: <<0x62, 0x01, 0x02>>},
               %{local_coord: {0, 0, 0}, payload: <<0x62, 0xAA>>}
             ])

    assert binary_part(shard, byte_size(shard) - 4, 4) == "VXFT"
    assert {:ok, <<0x62, 0x01, 0x02>>} = WorldPackShard.fetch(shard, {13, 0, 13})
    assert {:ok, <<0x62, 0xAA>>} = WorldPackShard.fetch(shard, {0, 0, 0})
    assert {:error, :not_found} = WorldPackShard.fetch(shard, {14, 0, 13})
  end

  test "reads payloads from a vxpack file by footer offset" do
    path = temp_path()
    on_exit(fn -> File.rm(path) end)

    assert {:ok, shard} =
             WorldPackShard.encode([
               %{local_coord: {1, 2, 3}, payload: <<0x62, 0x10>>},
               %{local_coord: {4, 5, 6}, payload: <<0x62, 0x20, 0x21>>}
             ])

    File.write!(path, shard)

    assert {:ok, <<0x62, 0x20, 0x21>>} = WorldPackShard.fetch_file(path, {4, 5, 6})
    assert {:error, :not_found} = WorldPackShard.fetch_file(path, {7, 8, 9})

    assert {:ok, summary} = WorldPackShard.footer_summary_file(path)
    assert summary.entry_count == 2
    assert MapSet.equal?(summary.local_coords, MapSet.new([{1, 2, 3}, {4, 5, 6}]))
  end

  test "rejects invalid entries without producing partial shard data" do
    assert {:error, :empty_entries} = WorldPackShard.encode([])

    assert {:error, {:invalid_local_coord, [1, 2]}} =
             WorldPackShard.encode([%{local_coord: [1, 2], payload: <<1>>}])

    assert {:error, {:invalid_payload, ""}} =
             WorldPackShard.encode([%{local_coord: {0, 0, 0}, payload: ""}])
  end
end
