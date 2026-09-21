defmodule SceneServer.PrefabDesigner do
  @moduledoc """
  全局系统功能：无状态 prefab 设计检查，通过 World 正式入口发布。

  `check/5` 接收解码后的 v3 草稿或 VXPD 字节、actor 或角色编号，以及显式的
  `entry` / `inside` 世界 micro 脚点。可选 `interiors` 是带名称、整数 `floor_y`
  的 micro XZ 半开矩形；`ground_y` 显式提供草稿地面平面。`anchor` 是世界 micro
  锚点，`orientation` 沿用 prefab 旋转。不得猜测房间范围或工地地形。

  路线、屋顶、净空和悬空报告仅针对草稿。放置报告读取当前 World 占用；出生报告
  标记受影响的探测列，不代表出生或放置许可。角色编号仅选择余额投影；实际发布
  与放置仍由 World 鉴权裁决。检查窗口各轴最多 24 米，扫描工作量与寻路节点有界。
  """
  alias SceneServer.Movement.Scene
  alias SceneServer.PrefabDesigner.Check
  alias VoxelRegion.{Attachments, Prefab, Spatial, World}
  alias MmoContracts.Voxel.{Codec, Payload}
  @micro Spatial.micro_resolution()
  @axis_limit 24 * @micro
  @scan_limit @axis_limit * @axis_limit * @axis_limit
  @path_limit 50_000

  def publish(world, actor, draft), do: World.publish_prefab(world, actor, bytes(draft))

  def check(world, scene, actor, draft, opts) do
    with :ok <- accept_options(opts),
         {:ok, id, compiled} <- Prefab.compile(bytes(draft), World.prefab_catalog(world)),
         :ok <- alignment(compiled, Keyword.get(opts, :anchor, {0, 0, 0})) do
      context = Scene.design_context(scene)
      compiled = transform(compiled, Keyword.get(opts, :anchor, {0, 0, 0}), Keyword.get(opts, :orientation, 0))
      with {:ok, bounds} <- bounds(compiled, context.profile, opts),
           {:ok, report} <- Check.run(compiled, Keyword.merge(opts,
             bounds: bounds, profile: context.profile, properties: World.material_catalog(world),
             max_path_nodes: @path_limit, max_scan_cells: @scan_limit)),
           {:ok, snapshot, conflicts} <- placement(world, character(actor), compiled) do
        balances = Map.new(snapshot.material_balances, &{&1.material, &1.units})
        balances = Map.new(report.materials.units, fn {m, _} -> {m, Map.get(balances, m, 0)} end)
        shortages = for {m, n} <- report.materials.units, n > balances[m], into: %{}, do: {m, n - balances[m]}
        {:ok, Map.merge(report, %{definition_id: id, world_seq: snapshot.seq,
          materials: Map.merge(report.materials, %{balances: balances, shortages: shortages, affordable: map_size(shortages) == 0}),
          placement: %{conflicts: conflicts, spawn_scope: :probe_column,
            spawn_probes: spawn_probes(compiled, context)}})}
      end
    end
  end

  defp bytes(bytes) when is_binary(bytes), do: bytes
  defp bytes(draft), do: Prefab.encode(draft)
  defp character(%{cid: cid}), do: cid
  defp character(cid) when is_integer(cid), do: cid
  defp point?({x, y, z}), do: is_integer(x) and is_integer(y) and is_integer(z)
  defp point?(_), do: false

  defp accept_options(opts) do
    cond do
      not point?(opts[:entry]) or not point?(opts[:inside]) -> {:error, :missing_check_points}
      not point?(Keyword.get(opts, :anchor, {0, 0, 0})) or Keyword.get(opts, :orientation, 0) not in 0..23 -> {:error, :invalid_transform}
      opts[:ground_y] != nil and not is_integer(opts[:ground_y]) -> {:error, :invalid_ground}
      not is_list(Keyword.get(opts, :interiors, [])) or not Enum.all?(Keyword.get(opts, :interiors, []), &interior?/1) -> {:error, :invalid_interior}
      true -> :ok
    end
  end
  defp interior?(%{name: _, floor_y: y, min: {x, z}, max: {xx, zz}}),
    do: Enum.all?([x, z, xx, zz, y], &is_integer/1) and xx > x and zz > z
  defp interior?(_), do: false

  defp alignment(%{has_macro_cells: true}, anchor) do
    if Enum.all?(Tuple.to_list(anchor), &(rem(&1, @micro) == 0)), do: :ok, else: {:error, :misaligned}
  end
  defp alignment(_, _), do: :ok

  defp transform(compiled, anchor, orientation) do
    macros = Map.new(Prefab.macro_occurrences(compiled, anchor, orientation, 1), fn {id, _, cells} -> {id, cells} end)
    attachments = Enum.group_by(Prefab.attachments(compiled, anchor, orientation, 1), & &1.owner)
    nodes = for {id, _, cells} <- Prefab.occurrences(compiled, anchor, orientation, 1),
      do: %{cells: cells, macro_cells: macros[id], attachments: Map.get(attachments, id, [])}
    %{compiled | nodes: nodes}
  end

  defp boxes(compiled) do
    (for {p, _} <- Prefab.footprint(compiled, {0, 0, 0}, 0), do: {p, add(p, {1, 1, 1})}) ++
      (for {p, _} <- Prefab.macro_footprint(compiled, {0, 0, 0}, 0) do
        lo = p |> Tuple.to_list() |> Enum.map(&(&1 * @micro)) |> List.to_tuple()
        {lo, add(lo, {@micro, @micro, @micro})}
      end)
  end
  defp add(a, b), do: List.to_tuple(for i <- 0..2, do: elem(a, i) + elem(b, i))

  defp bounds(compiled, profile, opts) do
    room_points = for r <- Keyword.get(opts, :interiors, []), p <- [
      {elem(r.min, 0), r.floor_y, elem(r.min, 1)}, {elem(r.max, 0), r.floor_y + 1, elem(r.max, 1)}], do: p
    points = [opts[:entry], opts[:inside] | room_points] ++ Enum.flat_map(boxes(compiled), fn {a, b} -> [a, b] end)
    radius = ceil(profile.radius * @micro) + 1
    height = ceil((2 * profile.half_height + profile.step_height) * @micro) + 1
    lo = List.to_tuple(for i <- 0..2, do: Enum.min(Enum.map(points, &elem(&1, i))) - if(i == 1, do: 1, else: radius))
    hi = List.to_tuple(for i <- 0..2, do: Enum.max(Enum.map(points, &elem(&1, i))) + if(i == 1, do: height, else: radius))
    if Enum.all?(0..2, &(elem(hi, &1) - elem(lo, &1) <= @axis_limit)), do: {:ok, {lo, hi}}, else: {:error, :check_budget}
  end

  defp placement(world, cid, compiled) do
    macros = MapSet.new(for {p, _} <- Prefab.macro_footprint(compiled, {0, 0, 0}, 0), do: p)
    micros = Prefab.footprint(compiled, {0, 0, 0}, 0) |> Enum.map(fn {p, _} -> Prefab.macro_slot(p) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    snapshot = World.material_snapshot(world, [cid], Enum.uniq(MapSet.to_list(macros) ++ Map.keys(micros)))
    refined = for probe <- snapshot.probe_occupancy, probe.refined and is_map_key(micros, List.to_tuple(probe.cell)), do: List.to_tuple(probe.cell)
    attachments = for node <- compiled.nodes, group <- node.attachments, slot <- group.slots, do: slot
    attachment_cells = Enum.map(attachments, &elem(Prefab.macro_slot(elem(&1, 2)), 0))
    with {:ok, payloads} <- payloads(world, refined ++ attachment_cells),
         :ok <- same_world(world, snapshot.seq) do
      conflicts = Enum.flat_map(snapshot.probe_occupancy, fn probe ->
        cell = List.to_tuple(probe.cell)
        base = %{cell: cell, material: probe.material, placed_by: probe.placed_by}
        cond do
          probe.material != 0 -> [Map.put(base, :reason, :occupied)]
          MapSet.member?(macros, cell) and probe.refined -> [Map.put(base, :reason, :refined)]
          probe.refined ->
            payload = Map.fetch!(payloads, region(cell))
            slots = Map.fetch!(payload.refined, Payload.cell_index(Payload.local(payload.region, cell)))
            overlap = Enum.filter(micros[cell], &Map.has_key?(slots, &1)) |> Enum.sort()
            if overlap == [], do: [], else: [Map.merge(base, %{reason: :occupied_micro, slots: overlap})]
          true -> []
        end
      end)
      conflicts = conflicts ++ Enum.flat_map(attachments, fn slot ->
        payload = Map.fetch!(payloads, Attachments.region(slot))
        case Map.fetch(payload.attachments, slot) do
          {:ok, {instance, material}} -> [%{cell: elem(Prefab.macro_slot(elem(slot, 2)), 0),
            reason: :occupied_attachment, slot: slot, instance: instance, material: material}]
          :error -> []
        end
      end)
      with :ok <- same_world(world, snapshot.seq),
        do: {:ok, snapshot, Enum.sort_by(conflicts, & &1.cell)}
    end
  end

  defp same_world(world, seq), do: if(World.seq(world) == seq, do: :ok, else: {:error, :world_changed})

  defp region(cell), do: cell |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1, Payload.extent() - 2)) |> List.to_tuple()
  defp payloads(_, []), do: {:ok, %{}}
  defp payloads(world, cells) do
    requests = cells |> Enum.map(&region/1) |> Enum.uniq() |> Enum.map(&%{level: 0, region: &1, have_seq: 0, have_hash: 0})
    request = Codec.encode_request(0, requests) |> IO.iodata_to_binary()
    with {:ok, reply} <- World.serve(world, request),
         {:ok, _, rows} <- Codec.decode_reply(IO.iodata_to_binary(reply)) do
      Enum.reduce_while(rows, {:ok, %{}}, fn
        {:payload, 0, r, bytes}, {:ok, acc} ->
          case Payload.decode(bytes) do
            {:ok, p} -> {:cont, {:ok, Map.put(acc, r, p)}}
            error -> {:halt, error}
          end
        _, _ -> {:halt, {:error, :world_payload_unavailable}}
      end)
    end
  end

  defp spawn_probes(compiled, context) do
    boxes = boxes(compiled)
    for {x, y, z} = probe <- context.probes do
      lo = {(x - context.profile.radius) * @micro, context.spawn_min_y * @micro, (z - context.profile.radius) * @micro}
      hi = {(x + context.profile.radius) * @micro, (y + 2 * context.profile.half_height) * @micro, (z + context.profile.radius) * @micro}
      affected = Enum.any?(boxes, fn {a, b} -> Enum.all?(0..2, &(elem(a, &1) < elem(hi, &1) and elem(b, &1) > elem(lo, &1))) end)
      %{probe: probe, status: if(affected, do: :affected, else: :clear)}
    end
  end
end
