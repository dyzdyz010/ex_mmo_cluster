defmodule VoxelRegion.RegionServeSnapshotTest do
  @moduledoc "只测试：真实 World 冻结区域输入，编码跨回合后仍保持切点，旧结果不得回填当前缓存。来源为确定的全空气夹具。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, TestSupport}
  alias VoxelRegion.World.{PageLoad, Payloads}
  alias MmoContracts.Voxel.{Codec, Payload}

  setup do
    root = Path.join(System.tmp_dir!(), "serve_snapshot_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    world = start_supervised!({World, source: TestSupport.Source, log: TestSupport.Log,
      root: root, observer: self(), name: nil, property_catalog_path: nil, prefab_catalog_path: nil})
    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world}
  end

  test "冻结后编辑可继续，编码返回原切点且旧字节不污染新请求", %{world: world} do
    assert {:ok, 1} = World.apply_edit(world, {1, 1, 1}, 11)
    item = %{level: 0, region: {0, 0, 0}, have_seq: 0, have_hash: 0}
    {token, job} = freeze(world, item)
    assert {:encode, _, _, 1, 123} = job.input

    assert {:ok, 2} = World.apply_edit(world, {1, 1, 1}, 19)
    {{:payload, 0, {0, 0, 0}, old}, cache} = Payloads.encode_reply(job)
    assert {:ok, old_payload} = Payload.decode(old)
    assert old_payload.seq == 1
    assert binary_part(old_payload.cells, Payload.cell_index({2, 2, 2}) * 2, 2) == <<11, 0>>
    finish(world, token, job, item, cache, :payload)

    assert {:ok, response} = World.serve(world, IO.iodata_to_binary(Codec.encode_request(123, [item])))
    assert {:ok, 123, [{:payload, 0, {0, 0, 0}, bytes}]} = Codec.decode_reply(IO.iodata_to_binary(response))
    assert {:ok, current} = Payload.decode(bytes)
    assert current.seq == 2
    assert binary_part(current.cells, Payload.cell_index({2, 2, 2}) * 2, 2) == <<19, 0>>
  end

  test "已知基底的增量、重复请求、错误 hash 和 unchanged 仍遵循同一协议", %{world: world} do
    assert {:ok, 1} = World.apply_edit(world, {1, 1, 1}, 11)
    item = %{level: 0, region: {0, 0, 0}, have_seq: 0, have_hash: 0}
    assert [{:payload, 0, {0, 0, 0}, base}] = request(world, item)
    {:ok, header} = Codec.decode_payload_header(base)
    item = %{item | have_seq: header.seq, have_hash: header.hash}
    assert [{:unchanged, 0, {0, 0, 0}}] = request(world, item)
    assert {:ok, 2} = World.apply_edit(world, {2, 1, 1}, 19)
    assert [{:entries, 0, {0, 0, 0}, [txn]}] = request(world, item)
    assert txn.seq == 2
    assert [%{coord: {2, 1, 1}, material: 19}] = txn.entries
    assert [{:entries, 0, {0, 0, 0}, [^txn]}] = request(world, item)
    assert [{:payload, 0, {0, 0, 0}, _}] = request(world, %{item | have_hash: header.hash + 1})
  end

  test "无关区域提交不废弃已经冻结区域的编码结果", %{world: world} do
    assert {:ok, 1} = World.apply_edit(world, {1, 1, 1}, 11)
    item = %{level: 0, region: {0, 0, 0}, have_seq: 0, have_hash: 0}
    {token, job} = freeze(world, item)
    assert {:encode, _, _, 1, 123} = job.input
    assert {:ok, 2} = World.apply_edit(world, {1024, 1, 1}, 19)
    {reply, cache} = Payloads.encode_reply(job)
    finish(world, token, job, item, cache, elem(reply, 0))
    {next_token, next_job} = freeze(world, item)
    assert {:bytes, _, _} = next_job.input
    GenServer.cast(world, {:release_preparation, next_token, self()})
  end

  test "邻区修改 ring 时撤销冻结结果，作用域取消也拒绝回填", %{world: world} do
    assert {:ok, 1} = World.apply_edit(world, {1, 1, 1}, 11)
    item = %{level: 0, region: {0, 0, 0}, have_seq: 0, have_hash: 0}
    {token, job} = freeze(world, item)
    assert {:ok, 2} = World.apply_edit(world, {64, 1, 1}, 19)
    {reply, cache} = Payloads.encode_reply(job)
    finish(world, token, job, item, cache, elem(reply, 0))
    {next_token, next_job} = freeze(world, item)
    assert {:encode, _, _, 2, 123} = next_job.input
    {_, {bytes, _}} = Payloads.encode_reply(next_job)
    {:ok, p} = Payload.decode(bytes)
    assert binary_part(p.cells, Payload.cell_index({65, 2, 2}) * 2, 2) == <<19, 0>>
    GenServer.cast(world, {:release_preparation, next_token, self()})
    {reply, cache} = Payloads.encode_reply(next_job)
    finish(world, next_token, next_job, item, cache, elem(reply, 0))
    {last_token, last_job} = freeze(world, item)
    assert {:encode, _, _, 2, 123} = last_job.input
    GenServer.cast(world, {:release_preparation, last_token, self()})
    assert World.residency_status(world).preparations == 0
  end

  defp freeze(world, item) do
    {token, _, _, _} = PageLoad.call(world, {:prepare, [{item.level, item.region}]}, 60_000)
    {:ok, job} = PageLoad.call(world, {:serve_item, token, 123, item}, 60_000)
    {token, job}
  end

  defp finish(world, token, job, item, cache, kind) do
    assert :ok = PageLoad.call(world, {:serve_result, token, job.cache_ref, item, cache, kind})
    GenServer.cast(world, {:release_preparation, token, self()})
  end

  defp request(world, item) do
    {:ok, response} = World.serve(world, IO.iodata_to_binary(Codec.encode_request(123, [item])))
    {:ok, 123, items} = Codec.decode_reply(IO.iodata_to_binary(response))
    items
  end
end
