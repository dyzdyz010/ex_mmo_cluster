defmodule GateServer.Npc.Skills.Design do
  @moduledoc """
  全局系统功能：有界住宅设计会话。调用方在技能 worker 中同步调用，不占用 Body 节拍。
  草稿复用 Prefab.Draft；完整 Responses 消息与工具结果只属于本次会话，世界仍由 World 裁决。
  住宅验收是本技能的发布条件，不增加 D1 或 World 的发布、放置权限。
  token 预算按响应 usage 累计，超限响应不执行工具；这不是单次请求前的费用硬封顶。
  缺失 usage 时停止，metrics.usage_complete 为 false，已知累计值不会伪装成完整用量。
  """
  alias VoxelRegion.{Prefab, World, Spatial}
  alias VoxelRegion.Prefab.Draft
  alias SceneServer.{PrefabDesigner, Movement.Scene}
  alias SceneServer.PrefabDesigner.Check

  @metrics %{request_count: 0, rounds: 0, input_tokens: 0, output_tokens: 0,
    total_tokens: 0, failed_checks: 0, usage_complete: true}

  @doc "返回发布结果或明确失败及实际模型计量；模型请求由 context.request 注入。"
  def run(context, args) do
    catalog = World.prefab_catalog(context.world)
    properties = World.material_catalog(context.world)
    scene = Scene.design_context(context.scene)
    initial = %{goal: args.goal, anchor_micro: args.anchor, orientation: args.orientation,
      session_budget: context.budget,
      draft: %{macro_cells: 0,micro_cells: 0,child_slots: []},
      orientations: %{columns: [:id,:local_x_direction,:local_y_direction,:local_z_direction],
        rows: for(o <- 0..23,do: [o|Enum.map([{1,0,0},{0,1,0},{0,0,1}],&Prefab.point(&1,{0,0,0},o))])},
      profile: Map.take(scene.profile, [:radius, :half_height, :step_height]),
      site: site(context, args.anchor), spawn_probes_m: scene.probes,
      materials: for({id, row} <- Enum.sort(properties.materials), do:
        %{id: id, name: row["display_name"], blocks_movement: MmoContracts.VoxelMaterialCatalog.blocks_movement?(id)}),
      limits: Prefab.limits(), catalog: catalog_rows(catalog, properties, context.labels)}
    state = %{draft: Draft.new(), history: [%{"role" => "user", "content" => encode(initial)}],
      metrics: @metrics, last_check: nil, profile: scene.profile}
    loop(context, args, state)
  end

  # 只报告锚点下层与起层的有限观测；未采样附件、上层或窗口外不推断为空。
  defp site(context, anchor) do
    [x,y,z] = anchor |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1,Spatial.micro_resolution()))
    cells = for yy <- (y-1)..y, xx <- x..(x+15), zz <- z..(z+15), do: {xx,yy,zz}
    snapshot = World.material_snapshot(context.world,[context.actor.cid],cells)
    layers = for yy <- (y-1)..y do
      rows = Enum.filter(snapshot.probe_occupancy, &(Enum.at(&1.cell,1) == yy))
      values = Enum.map(rows, &Map.take(&1,[:material,:refined,:placed_by])) |> Enum.uniq()
      case values do
        [%{refined: false} = uniform] -> %{macro_y: yy, uniform: uniform}
        _ ->
          normal = for row <- rows,not row.refined,row.material != 0 or row.placed_by != nil,
            do: [Enum.at(row.cell,0),Enum.at(row.cell,2),row.material,row.placed_by]
          %{macro_y: yy,normal_columns: [:x,:z,:material,:placed_by],normal: normal,
            refined: Enum.filter(rows,& &1.refined),unlisted: :air_unowned_unrefined}
      end
    end
    %{bounds_macro: {{x,y-1,z},{x+16,y+1,z+16}}, sampled_cells: length(cells),
      world_seq: snapshot.seq, material_balances: snapshot.material_balances, layers: layers,
      attachments: :not_sampled, outside: :unknown}
  end

  defp catalog_rows(catalog, properties, labels) do
    for {id, compiled} <- Enum.sort(catalog) do
      hex = Base.encode16(id, case: :lower)
      {lo, hi} = compiled.summary.bounds
      %{id: hex, label: Map.get(labels, hex), summary: compiled.summary,
        size_m: for(i <- 0..2, do: (elem(hi,i) - elem(lo,i)) / Spatial.micro_resolution()),
        materials: Check.materials(compiled, properties)}
    end
  end

  defp loop(context, args, state) do
    cond do
      state.metrics.rounds >= context.budget.rounds -> {:error, :round_budget, state.metrics}
      state.metrics.total_tokens >= context.budget.tokens -> {:error, :token_budget, state.metrics}
      true -> request(context, args, state)
    end
  end

  defp request(context, args, state) do
    body = %{model: context.endpoint.model, instructions: instructions(), input: state.history,
      tools: tools(), tool_choice: "required", parallel_tool_calls: false, store: false,
      reasoning: %{effort: Map.get(context.endpoint, :effort, "low")},
      max_output_tokens: min(context.budget.max_output_tokens, context.budget.tokens - state.metrics.total_tokens)}
    state = update_in(state.metrics.request_count, &(&1 + 1))
    case context.request.(context.endpoint, body) do
      {:ok, response} ->
        state = update_in(state.metrics.rounds, &(&1 + 1))
        case usage(response, state.metrics) do
          {:ok, metrics} when metrics.total_tokens <= context.budget.tokens ->
            state = %{state | metrics: metrics}
            case call(response) do
              {:ok, id, name, params} ->
                state = %{state | history: state.history ++ response["output"]}
                case execute(name, params, context, args, state) do
                  {:continue, result, next} ->
                    result = Map.put(result,:remaining_budget,%{rounds: context.budget.rounds-next.metrics.rounds,
                      tokens: context.budget.tokens-next.metrics.total_tokens})
                    output = %{"type" => "function_call_output", "call_id" => id, "output" => encode(result)}
                    loop(context, args, %{next | history: next.history ++ [output]})
                  {:done, result} -> {:ok, Map.put(result, :metrics, state.metrics)}
                end
              {:error, reason} -> {:error, reason, state.metrics}
            end
          {:ok, metrics} -> {:error, :token_budget, metrics}
          {:error, reason} -> {:error, reason, %{state.metrics | usage_complete: false}}
        end
      {:error, reason} -> {:error, {:request_failed, reason}, %{state.metrics | usage_complete: false}}
    end
  end

  defp usage(%{"usage" => %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => total}}, metrics)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and total == input + output do
    {:ok, %{metrics | input_tokens: metrics.input_tokens + input, output_tokens: metrics.output_tokens + output,
      total_tokens: metrics.total_tokens + total}}
  end
  defp usage(_, _), do: {:error, :usage_unavailable}

  defp call(%{"output" => output}) when is_list(output) do
    case Enum.filter(output, &(is_map(&1) and &1["type"] == "function_call")) do
      [%{"call_id" => id, "name" => name, "arguments" => json}] when is_binary(id) and is_binary(json) ->
        cond do
          name not in ["edit", "view", "slice", "check", "publish"] -> {:error, {:unknown_tool, name}}
          true -> case Jason.decode(json) do
            {:ok, %{} = params} -> {:ok, id, name, params}
            _ -> {:error, :invalid_tool_arguments}
          end
        end
      _ -> {:error, :expected_one_tool}
    end
  end
  defp call(_), do: {:error, :invalid_model_response}

  defp execute("edit", %{"ops" => ops}, _, _, state) do
    case Draft.edit(state.draft, ops) do
      {:ok, draft} -> {:continue, %{ok: true, macro_cells: length(draft.macro_cells), micro_cells: length(draft.cells),
        child_slots: Enum.map(draft.children, & &1.slot)}, %{state | draft: draft, last_check: nil}}
      {:error, reason} -> rejected(reason, state)
    end
  end
  defp execute("view", params, context, _, state) when map_size(params) == 0 do
    with {:ok, bytes} <- draft_bytes(state.draft),
         {:ok,id,geometry,diagnostics} <- Prefab.preview(bytes,World.prefab_catalog(context.world)),
         {:ok, views} <- Check.view(geometry) do
      {:continue, %{ok: true, definition_id: id, scope: :draft_local, views: views,
        diagnostics: preview_output(diagnostics),components: state.draft.children}, state}
    else
      {:error, reason} -> rejected(reason, state)
    end
  end
  defp execute("slice", %{"target"=>target,"axis"=>axis,"at"=>at},context,_,state) do
    with {:ok,id,geometry,scope} <- slice_target(target,context,state.draft),
         {:ok,section} <- Check.slice(geometry,axis,at) do
      {:continue,%{ok: true,definition_id: id,scope: scope,section: section},state}
    else
      {:error,reason} -> rejected(reason,state)
    end
  end
  defp execute("check", params, context, args, state) do
    with {:ok, opts} <- check_options(params),
         {:ok, report} <- PrefabDesigner.check(context.world, context.scene, context.actor, state.draft,
           Keyword.merge(opts, anchor: args.anchor, orientation: args.orientation)) do
      checked = acceptance(report, state.profile, opts)
      metrics = if checked.passed, do: state.metrics, else: %{state.metrics | failed_checks: state.metrics.failed_checks + 1}
      {:continue, %{ok: true, check: check_output(checked)}, %{state | last_check: checked, metrics: metrics}}
    else
      {:error, reason} ->
        state = %{state | last_check: nil, metrics: %{state.metrics | failed_checks: state.metrics.failed_checks + 1}}
        rejected(reason, state)
    end
  end
  defp execute("publish", params, context, _, %{last_check: %{passed: true} = checked} = state) when map_size(params) == 0 do
    with {:ok, id, compiled} <- compile(context, state.draft),
         true <- id == checked.definition_id,
         {:ok, ^id} <- PrefabDesigner.publish(context.world, context.actor, state.draft) do
      {:done, %{definition_id: id, summary: compiled.summary, check: checked}}
    else
      false -> rejected(:check_required, state)
      {:error, reason} -> rejected(reason, state)
    end
  end
  defp execute("publish", params, _, _, state) when map_size(params) == 0,
    do: rejected(if(state.last_check == nil, do: :check_required, else: :check_failed), state)
  defp execute(_, _, _, _, state), do: rejected(:invalid_tool_arguments, state)
  defp rejected(reason, state), do: {:continue, %{ok: false, error: reason}, state}

  defp compile(context, draft) do
    with {:ok,bytes} <- draft_bytes(draft),do: Prefab.compile(bytes,World.prefab_catalog(context.world))
  end
  defp draft_bytes(draft) do
    if draft.cells == [] and draft.macro_cells == [] and draft.children == [] and draft.attachments == [],
      do: {:error, :empty_draft},
      else: {:ok,Prefab.encode(draft)}
  end
  defp slice_target("draft",context,draft) do
    with {:ok,bytes} <- draft_bytes(draft),
         {:ok,id,geometry,_} <- Prefab.preview(bytes,World.prefab_catalog(context.world)),
         do: {:ok,id,geometry,:draft_local}
  end
  defp slice_target(target,context,_) when is_binary(target) do
    with {:ok,<<id::binary-size(32)>>} <- Base.decode16(target,case: :mixed),
         {:ok,compiled} <- Map.fetch(World.prefab_catalog(context.world),id) do
      {:ok,id,compiled,:catalog_local}
    else
      _ -> {:error,:definition_not_found}
    end
  end
  defp slice_target(_,_,_),do: {:error,:invalid_view}
  defp preview_output(diagnostics),do: Map.update!(diagnostics,:overlaps,fn overlaps ->
    Map.new(overlaps,fn {kind,points}->{kind,floating_cells(points)} end)
  end)

  defp check_options(%{"entry" => entry, "inside" => inside, "interiors" => rooms}) when is_list(rooms) do
    with {:ok, entry} <- point(entry), {:ok, {x,y,z} = inside} <- point(inside), {:ok, rooms} <- rooms(rooms),
         true <- Enum.any?(rooms, &(y == &1.floor_y and x >= elem(&1.min,0) and x < elem(&1.max,0) and
           z >= elem(&1.min,1) and z < elem(&1.max,1))) do
      {:ok, [entry: entry, inside: inside, interiors: rooms]}
    else
      false -> {:error, :inside_outside_interiors}
      error -> error
    end
  end
  defp check_options(_), do: {:error, :invalid_check_arguments}
  defp point([x,y,z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {:ok,{x,y,z}}
  defp point(_), do: {:error, :invalid_check_arguments}
  defp rooms(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      %{"name" => name, "floor_y" => y, "min" => [x,z], "max" => [xx,zz]}, {:ok, acc}
        when is_binary(name) and is_integer(y) and is_integer(x) and is_integer(z) and is_integer(xx) and is_integer(zz) and xx > x and zz > z ->
          {:cont, {:ok, acc ++ [%{name: name, floor_y: y, min: {x,z}, max: {xx,zz}}]}}
      _, _ -> {:halt, {:error, :invalid_check_arguments}}
    end)
  end

  defp acceptance(report, profile, opts) do
    height = ceil(2 * profile.half_height * Spatial.micro_resolution())
    rooms = report.headroom.interiors
    headroom = is_integer(report.headroom.inside.clear_micro) and report.headroom.inside.clear_micro >= height and
      rooms != [] and Enum.all?(rooms, &(is_integer(&1.min_clear_micro) and &1.min_clear_micro >= height and &1.unknown_columns == 0))
    floating = report.floating
    {lo,hi} = report.geometry_bounds
    {x,_,z} = opts[:entry]
    outside = x < elem(lo,0) or x >= elem(hi,0) or z < elem(lo,2) or z >= elem(hi,2)
    criteria = %{
      entry: criterion(outside,:outside_complete_geometry_xz,%{point: opts[:entry],bounds: report.geometry_bounds}),
      route: criterion(match?({:ok, [_ | _]}, report.route), :reachable_inside, report.route),
      headroom: criterion(headroom, %{min_clear_micro: height}, report.headroom),
      roof: criterion(report.roof != [] and Enum.all?(report.roof, & &1.complete), :all_declared_rooms_covered, report.roof),
      floating: criterion(floating.status == :checked and floating.macro_cells == [] and floating.micro_cells == [],
        :connected_to_world_terrain, floating),
      materials: criterion(report.materials.affordable, :enough_inventory, report.materials),
      placement: criterion(report.placement.conflicts == [], :no_occupancy_conflict, report.placement.conflicts),
      spawn: criterion(Enum.all?(report.placement.spawn_probes, &(&1.status == :clear)), :clear_probe_columns, report.placement.spawn_probes)
    }
    reasons = for {name, %{passed: false}} <- Enum.sort(criteria), do: name
    %{passed: reasons == [], reasons: reasons, criteria: criteria, report: report,
      definition_id: report.definition_id, world_seq: report.world_seq}
  end
  defp criterion(passed, required, observed), do: %{passed: passed, required: required, observed: observed}

  # 模型只收一次诊断投影；完整逐格报告仍由 last_check 持有并用于验收和最终结果。
  defp check_output(checked) do
    criteria = Map.new(checked.criteria, fn {name,row} -> {name,Map.delete(row,:observed)} end)
    report = Map.update!(checked.report,:floating,&floating_output/1)
    %{checked | criteria: criteria, report: report}
  end
  defp floating_output(%{status: :checked,macro_cells: macros,micro_cells: micros}) do
    %{status: :checked,total_cells: length(macros)+length(micros),
      bounds_convention: :half_open_in_each_cell_resolution,
      sample_scope: :partial_coordinates_not_full_geometry,
      macro_cells: floating_cells(macros),micro_cells: floating_cells(micros)}
  end
  defp floating_output(report), do: report
  defp floating_cells([]), do: %{count: 0,bounds: nil,sample: []}
  defp floating_cells(cells) do
    lo = for axis <- 0..2, do: cells |> Enum.map(&elem(&1,axis)) |> Enum.min()
    hi = for axis <- 0..2, do: 1 + (cells |> Enum.map(&elem(&1,axis)) |> Enum.max())
    %{count: length(cells),bounds: {List.to_tuple(lo),List.to_tuple(hi)},sample: Enum.take(cells,4)}
  end

  defp instructions do
    "Design a habitable voxel house by editing, viewing, checking, repairing, and publishing. Start with the new empty draft shown in the input. Call exactly one tool per turn. " <>
      "Draft macro boxes use inclusive integer bounds; 1 macro = 1 metre, 8 micro = 1 metre, Y is up. " <>
      "walls fills only the XZ perimeter over its Y range, never the floor or roof; add those explicitly with fill. " <>
      "clear deletes only macro cells; micro with material 0 deletes a micro cell. prefab replaces the child at the same slot; remove_prefab deletes that slot. " <>
      "Draft cells and prefab child anchors are local; check entry/inside feet and room rectangles are WORLD micro coordinates. " <>
      "orientations lists the transformed local axis directions; the anchor is the local origin, so cells along a negative axis extend below the anchor. " <>
      "Use supplied content IDs and labels for details. A view shows local geometry (+ means micro detail, not a filled macro). " <>
      "view works even when geometry cannot be published and reports overlapping local coordinates; macro_micro coordinates are MACRO cells to resolve, micro_cells coordinates are MICRO. " <>
      "slice inspects an exact micro plane of draft or any catalog id. Use it to see component openings and stair direction instead of treating a bounding box as filled or guessing details. " <>
      "Explicitly declare nonempty room interiors. Route, clearance and support checks combine the draft with actual World terrain, never an assumed ground plane. " <>
      "site reports only its half-open WORLD macro bounds at world_seq; a uniform layer applies to that bounded XZ rectangle. " <>
      "Nonuniform layers use normal rows [WORLD x,WORLD z,material,placed_by] (null ownership is preserved); refined contains full original cell/slot records. " <>
      "Within that layer's bounded XZ rectangle only, cells absent from both lists are material 0, unowned and unrefined with no slots. " <>
      "Attachments were not sampled; upper layers and outside the bounds are unknown. Use the actual sampled materials and blocks_movement to select ground, never liquid as support. " <>
      "Entry must be outside the complete prefab geometry XZ bounding box, including all children; inside must belong to a declared room. " <>
      "Endpoint diagnostics use the real profile radius, height and standing rules; body/support hits explain invalid feet. " <>
      "A current check must pass outside entry, route, headroom, complete roof, no floating solids, material affordability, occupancy and spawn columns. " <>
      "Read every criterion and repair failures. Edits invalidate the previous check. Publishing saves a definition only; it does not place it. " <>
      "The session_budget and each remaining_budget limit this session, including check and publish calls. Tokens count all repeated history and reasoning input plus output. " <>
      "Reserve calls for repairs, a passing check and publication; use view or slice when needed to resolve geometry rather than repeating observations."
  end

  defp tools do
    point = %{type: "array", items: %{type: "integer"}, minItems: 3, maxItems: 3}
    pair = %{type: "array", items: %{type: "integer"}, minItems: 2, maxItems: 2}
    operation = %{type: "object", properties: %{
      op: %{type: "string", enum: ["fill", "walls", "clear", "micro", "prefab", "remove_prefab"]},
      min: point, max: point, cell: point, material: %{type: "integer"}, slot: %{type: "integer"},
      id: %{type: "string"}, anchor_micro: point, orientation: %{type: "integer", minimum: 0, maximum: 23}},
      required: ["op"], additionalProperties: false}
    room = %{type: "object", properties: %{name: %{type: "string"}, floor_y: %{type: "integer"}, min: pair, max: pair},
      required: ["name", "floor_y", "min", "max"], additionalProperties: false}
    [tool("edit", "Atomic ordered edits: fill/walls/clear use inclusive macro boxes. walls is only the XZ perimeter, no floor/roof. clear removes macros only. micro uses cell and material (0 deletes). prefab uses slot/id/anchor_micro/orientation and replaces that slot; remove_prefab uses slot. Child anchors are local micro.",
       %{ops: %{type: "array", items: operation}}, ["ops"]),
     tool("view", "Show local draft layers/elevations, component slots and overlap diagnostics even for an invalid draft. Viewing never approves publication.", %{}, []),
     tool("slice", "Inspect one exact local micro plane of target 'draft' or a catalog definition id. axis 0/1/2 fixes X/Y/Z at the integer at; other axes span the geometry bounds. Each character is one micro cell, not a projection.",
       %{target: %{type: "string"},axis: %{type: "integer",enum: [0,1,2]},at: %{type: "integer"}},["target","axis","at"]),
     tool("check", "Check this house combined with actual World terrain at its anchor. Explicit WORLD micro feet and half-open XZ rooms; terrain and support come from the World.",
       %{entry: point, inside: point, interiors: %{type: "array", items: room}}, ["entry", "inside", "interiors"]),
     tool("publish", "Publish only after the unchanged draft passes every house criterion.", %{}, [])]
  end
  defp tool(name, description, properties, required), do: %{type: "function", name: name, description: description,
    parameters: %{type: "object", properties: properties, required: required, additionalProperties: false}}

  defp encode(value), do: value |> plain() |> Jason.encode!()
  defp plain(%{} = value), do: Map.new(value, fn
    {:definition_id, <<_::256>> = id} -> {:definition_id, Base.encode16(id, case: :lower)}
    {key, item} -> {key, plain(item)}
  end)
  defp plain(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&plain/1)
  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)
  defp plain(value), do: value
end
