# 只测试（Test-only）：D0 本机 World 对照测量，不修改产品、共享 Demo 或数据库。
# apps/scene_server 下：PREFAB_MEASURE_OUT=<新目录> mix test --no-start ../../docs/10-active/cross-cutting/tools/prefab_scale_measure_test.exs
Code.require_file("../../../../apps/voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule PrefabScaleMeasure do
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, Prefab, CollisionSource}
  alias VoxelRegion.TestSupport.Source
  alias MmoContracts.Voxel.{Codec, Payload}
  alias SceneServer.Movement.CollisionUpdates
  alias SceneServer.Native.VoximMovement, as: Native

  # 上一轮 cottage-real/run.log 的四层冻结文本图；44 石 + 24 木，非当前 Demo 残留。
  @cottage [
    ["######", ".....#", "#....#", "######"],
    ["######", "......", "#....#", ".#####"],
    ["######", "#....#", "#....#", "######"],
    ["======", "======", "======", "======"]
  ]

  defp cottage do
    for {rows, y} <- Enum.with_index(@cottage), {row, z} <- Enum.with_index(rows),
        {char, x} <- Enum.with_index(String.to_charlist(row)), char != ?.,
        do: {{x,y,z}, if(char == ?#, do: 11, else: 19)}
  end

  defp shell do
    for x <- 0..9, y <- 0..7, z <- 0..9,
        x in [0,9] or y in [0,7] or z in [0,9], do: {{x,y,z},11}
  end

  defp bytes(cells, children) do
    body = for {{x,y,z},m} <- Enum.sort(cells), into: <<>>,
      do: <<x::signed-little-32,y::signed-little-32,z::signed-little-32,m::16-little>>
    refs = for {id,{x,y,z},slot} <- children, into: <<>>,
      do: <<slot::32-little,id::binary-size(32),x::signed-little-32,y::signed-little-32,z::signed-little-32,0>>
    <<"VXPD",1::32-little,length(cells)::32-little,body::binary,length(children)::32-little,refs::binary>>
  end

  defp write_definition(dir, bytes) do
    id = :crypto.hash(:sha256, bytes)
    File.write!(Path.join(dir, Base.encode16(id) <> ".vxpd"), bytes)
    id
  end

  # 两个一格窗框各 28 micro，一个两格门框 38 micro；均位于原来的空气中。
  defp parts(name) do
    window = for y <- 0..7, z <- 0..7, y in [0,7] or z in [0,7], do: {{0,y,z},19}
    door = for y <- 0..15, z <- 0..7, y == 15 or z in [0,7], do: {{0,y,z},19}
    anchors = if name == "cottage", do: [{40,8,8},{0,8,24},{0,0,8}],
      else: [{80,8,16},{80,8,32},{80,0,48}]
    Enum.zip([window,window,door], anchors)
  end

  defp measure(out, name, macros, representation, trial) do
    root = Path.join(out, "#{name}-#{representation}-#{trial}")
    catalog = Path.join(root, "catalog")
    File.mkdir_p!(catalog)
    details = parts(name)
    refs = for {{cells,anchor},slot} <- Enum.with_index(details),
      do: {write_definition(catalog, bytes(cells,[])), anchor, slot}
    expanded = for {{x,y,z},m} <- macros, dx <- 0..7, dy <- 0..7, dz <- 0..7,
      do: {{x*8+dx,y*8+dy,z*8+dz},m}
    root_bytes = bytes(if(representation == :micro, do: expanded, else: []), refs)
    id = write_definition(catalog, root_bytes)
    # v3 尚未实现：只记录设计段的精确编码字节数（count + 每格 14 字节），不交旧 decoder。
    definition_bytes = File.ls!(catalog) |> Enum.map(&(File.stat!(Path.join(catalog,&1)).size)) |> Enum.sum()
    definition_bytes = definition_bytes + if(representation == :mixed, do: 8 + 14*length(macros), else: 0)
    if representation == :mixed do
      File.write!(Path.join(root,"mixed-definition.json"),Jason.encode!(%{version: 3,
        macro_cells: Enum.map(macros,fn {p,m} -> %{cell: Tuple.to_list(p),material: m} end),
        children: Enum.map(refs,fn {id,a,s} -> %{definition_id: Base.encode16(id),anchor: Tuple.to_list(a),slot: s,orientation: 0} end)}))
    end
    {:ok, world} = World.start_link(source: Source, root: root, observer: self(), name: nil,
      property_catalog_path: nil, prefab_catalog_path: nil)
    {publish_us,:ok} = :timer.tc(fn -> World.publish_prefabs(world,catalog) end)
    anchor = {16,16,16}
    edits = for {{x,y,z},m} <- macros, do: {{x+2,y+2,z+2},m}
    macro_us = if representation == :mixed,
      do: elem(:timer.tc(fn -> assert {:ok,_} = World.apply_edits(world,edits) end),0), else: 0
    {micro_us,_} = :timer.tc(fn -> assert {:ok,_} = World.place_prefab(world,id,anchor,0) end)
    place_us = macro_us + micro_us
    txns = World.entries_after(world,0)
    transaction_bytes = Enum.sum(for txn <- txns, entry <- txn.entries,
      do: IO.iodata_length(Codec.encode_entry(entry)))
    request = Codec.encode_request(0,[%{level: 0,region: {0,0,0},have_seq: 0,have_hash: 0}]) |> IO.iodata_to_binary()
    {:ok,reply} = World.serve(world,request)
    {:ok,_,[{:payload,0,{0,0,0},payload_bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok,payload} = Payload.decode(payload_bytes)
    {capture_us,chunks} = :timer.tc(fn -> [CollisionSource.capture(payload,{0,0,0})] end)
    build = fn -> Native.set_chunks(Native.new_world(),CollisionUpdates.operations(chunks)) end
    build.()
    build_samples = for _ <- 1..5, do: elem(:timer.tc(build),0)
    world_collision = build.()
    assert {colliders,_,_} = Native.world_stats(world_collision)
    assert colliders > 0
    # 独立体积口径：每完整宏格 512，两个窗框 28×2，门框 38，共 94 micro。
    expected = length(macros)*512 + 94
    detail_cells = for {cells,a} <- details, {p,_} <- cells,
      do: Prefab.macro_slot(Prefab.point(p,Prefab.point(a,anchor,0),0)) |> elem(0)
    targets = Enum.uniq(Enum.map(edits,&elem(&1,0)) ++ detail_cells)
    rows = World.material_snapshot(world,[],targets).probe_occupancy
    actual = Enum.sum(for row <- rows,
      do: if(row.material != 0, do: 512, else: Enum.sum(Enum.map(row.slots,& &1.count))))
    assert actual == expected
    :ok = World.compact(world)
    log_bytes = File.stat!(Path.join(root,"overlay.log")).size
    result = %{name: name, representation: representation, trial: trial, macro_cells: length(macros),
      micro_detail_cells: 94, pure_micro_cells: expected, expanded_nodes: 4, depth: 2,
      definition_bytes: definition_bytes, publish_us: publish_us, place_us: place_us,
      macro_apply_us: macro_us, micro_place_us: micro_us,
      transaction_bytes: transaction_bytes, payload_bytes: byte_size(payload_bytes),
      occupancy_us: capture_us, collision_build_us: build_samples, colliders: colliders,
      checkpoint_bytes: log_bytes}
    GenServer.stop(world)
    result
  end

  @tag timeout: 600_000
  test "same cottage and 10x10x8 shell through author publication and real World" do
    Logger.configure(level: :warning)
    out = System.fetch_env!("PREFAB_MEASURE_OUT")
    File.mkdir_p!(out)
    assert 68 == length(cottage())
    assert 44 == Enum.count(cottage(), &(elem(&1,1)==11))
    assert 416 == length(shell())
    results = for {name,cells} <- [{"cottage",cottage()},{"shell",shell()}],
      representation <- [:micro,:mixed], trial <- 1..3 do
      result = measure(out,name,cells,representation,trial)
      IO.puts("PREFAB_D0 " <> Jason.encode!(result))
      File.write!(Path.join(out,"results.jsonl"),Jason.encode!(result)<>"\n",[:append])
      result
    end
    assert length(results) == 12
  end
end
