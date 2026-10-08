defmodule GateServer.Npc.Skills.Gather do
  @moduledoc """
  全局系统功能：从作者给定的采石盒里取天然格，直到自己某种材料的余额增加 `units`（角色能力函数库设计稿
  docs/10-active/cross-cutting/2026-10-07-character-capability-library.md §11 I3、§10 S6）。技能壳 + 纯函数
  `candidates/3`：只经 Body 的原子动作 `move_to` / `look` / `query_balances` / `probe_toward` / `use_tool`
  （内部 id `{:skill, 调用号, 步}`），与玩家逐格挖同一条裁决；不逐帧读观察（不声明 `observations?/0`）。

  流程：

  1. `World.tool_definition/2` 取这把工具的间隔（唯一读路径；够不够得着只由权威射线裁决，本地不按射程预检）；
  2. `query_balances` 取起始余额与该材料每格单位 `cost`；
  3. 站位 = `GateServer.Npc.Blueprint.stands/2`（盒子四条边中点外），按离自己由近到远逐个 `move_to`，位置取 done data；
  4. 每到一个站位 `look` 整盒（被拒原样作为终态，不另做盒大小预检），`candidates/3` 取候选并排序；
  5. 逐格：沿眼点 → 格心（`GateServer.Npc.WorldRequest.aim/2` 的 g0 瞄准点）`probe_toward`，命中恰是这一格的天然宏格
     （`granularity == 0`、`micro == 格 × 8`、`owner == {0, 0}`）才对这个句柄 `use_tool`，每击之后再探测，
     命中变了或 `no_target` 时 `look` 这一格：已是空气才算挖掉，否则留给下一个站位。命中别的东西、探测 `no_target`
     （射程外）、`out_of_reach` / `occluded` 也留给下一个站位；
     命中这一格但 owner 不是 `{0, 0}`（作者 prefab 宏格）永久跳过；`tool_cooldown` 等一个间隔再击，
     `stale_target` 重新探测；
  6. 按 `cost` 估算要挖的格数，估算挖够后 `query_balances` 核对，不足按差额继续。增量 ≥ units → done
     `%{mined, gained, skipped}`（挖掉的格数、余额实际增量、没挖成的候选数）；候选用尽 → `:exhausted`；
     一个站位都到不了 → `:unreachable`。其余拒绝（会话丢失、死亡、保护区等）原样作为终态。

  护栏（S6）：真正的护栏是作者给定的采石盒。`placed_by` 只能跳过有放置记录的格；作者 prefab 宏格只记
  macro_owners，由探测命中的 owner 核对挡住；被别的编辑改过的格与放置溯源升级前的格仍会被挖。原子 `use_tool`
  本身不加这条门，仍由权威裁决。

  采石盒要求（作者保证）：地表以上的料堆或深度不超过 1 层（坑沿会挡射线、寻路不跳坑）；盒内材料属于
  production_materials 且没有 drop_table（否则挖掉不入账）；盒子在 look 的上限内。
  """
  @behaviour GateServer.Npc.Skill
  alias GateServer.Npc.{Abilities, Actions, Blueprint, Body, Skill, WorldRequest}
  alias SceneServer.Movement.Player
  alias VoxelRegion.{Phase, Spatial}

  @metrics %{request_count: 0, jev_request_count: 0}
  # move_to 被这些原因拒绝 = 这个站位去不了，换下一个；其余拒绝原样作为终态。
  @unreachable [:no_path, :stuck, :too_far]
  # use_tool 被这些原因拒绝 = 从这个站位够不着这一格，留给下一个站位。
  @blocked [:out_of_reach, :occluded]

  @impl true
  def definition(profile) do
    %{
      description:
        "从采石盒里挖天然格，直到自己 balances 里 material 的余额增加 units（单位与 balances 相同）。" <>
          "box 是整数格闭区间 [[x0,y0,z0],[x1,y1,z1]]（1 格 = 1 米），受 look 的格数上限约束；技能自己走到盒子四周的站位、" <>
          "逐格探测后再挖，只挖材质为 material、没有放置记录的天然格，别人放下的格与预制件不挖。" <>
          "tool_id 用挖掘工具（见 read_catalog tools）。盒里不够时以 exhausted 结束，盒子四周都走不到时以 unreachable 结束。",
      parameters: %{
        type: "object",
        properties: %{
          box: %{
            type: "array",
            items: %{type: "array", items: %{type: "integer"}, minItems: 3, maxItems: 3},
            minItems: 2,
            maxItems: 2
          },
          material: %{type: "integer"},
          units: %{type: "integer"},
          tool_id: Abilities.belt_schema(profile)
        },
        required: ["box", "material", "units", "tool_id"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def run(
        context,
        %{
          "box" => [[x0, y0, z0], [x1, y1, z1]],
          "material" => material,
          "units" => units,
          "tool_id" => tool
        },
        _config
      )
      when is_integer(x0) and is_integer(y0) and is_integer(z0) and is_integer(x1) and
             is_integer(y1) and is_integer(z1) and is_integer(material) and is_integer(units) and
             units > 0 and is_integer(tool) do
    state = %{
      body: context.body,
      call: context.call_id,
      step: 0,
      box: {{min(x0, x1), min(y0, y1), min(z0, z1)}, {max(x0, x1), max(y0, y1), max(z0, z1)}},
      material: material,
      units: units,
      tool: tool
    }

    # 工具不在目录里、材料不是本世界的生产材料（余额表里没有它）：参数不成立，不动手。
    with {:ok, definition} <- VoxelRegion.World.tool_definition(context.world, tool),
         {:ok, %{balances: balances}, state} <- call(state, %{verb: :query_balances}),
         %{balance: start, cost: cost} <- Enum.find(balances, &(&1.material == material)) do
      state =
        Map.merge(state, %{
          interval_ms: round(definition["interval_seconds"] * 1_000),
          last_hit: nil,
          start: start,
          cost: cost,
          need: ceil(units / cost),
          mined: 0,
          gained: 0,
          # 没挖成的候选：:foreign = 命中这一格但不是天然宏格（永久跳过），:blocked = 从当时的站位够不着。
          skipped: %{},
          reached: false
        })

      {px, _, pz} = context.observation.self.position
      {lo, hi} = state.box
      visit(Blueprint.stands(%{lo => material, hi => material}, {floor(px), 0, floor(pz)}), state)
    else
      {:error, reason, _state} -> {:error, reason, @metrics}
      _ -> {:error, :invalid_skill_arguments, @metrics}
    end
  end

  def run(_, _, _), do: {:error, :invalid_skill_arguments, @metrics}

  @doc """
  采石候选（纯函数）：look 的逐格行里材质为 `material`、非空气、非液体、非细化、没有放置记录（`placed_by == nil`）
  且在 `box`（`{{x0,y0,z0},{x1,y1,z1}}`，闭区间）内的格，按层自上而下、同层离站位 `{x, z}` 水平距离由近到远排序
  （再按坐标定序）。返回 `[{x, y, z}]`。
  """
  def candidates(rows, %{box: {{x0, y0, z0}, {x1, y1, z1}}, material: material}, {sx, sz}) do
    for %{cell: [x, y, z], material: ^material, refined: false, placed_by: nil} <- rows,
        material != 0 and not Phase.liquid?(material),
        x in x0..x1 and y in y0..y1 and z in z0..z1 do
      {x, y, z}
    end
    |> Enum.sort_by(fn {x, y, z} ->
      {-y, (x + 0.5 - sx) * (x + 0.5 - sx) + (z + 0.5 - sz) * (z + 0.5 - sz), x, z}
    end)
  end

  # —— 站位循环 ——

  defp visit([], state), do: finish(state)

  defp visit([stand | rest], state) do
    case call(state, %{verb: :move_to, position: stand, tolerance: Actions.tolerance()}) do
      {:ok, %{position: {px, _, pz} = position}, state} ->
        {lo, hi} = state.box

        with {:ok, %{probe_occupancy: rows}, state} <- call(state, %{verb: :look, min: lo, max: hi}) do
          cells =
            candidates(rows, state, {px, pz})
            |> Enum.reject(&(state.skipped[&1] == :foreign))

          case dig(cells, Player.eye_position(position), %{state | reached: true}) do
            {:done, state} ->
              done(state)

            # 本站位的候选都试过了：有够不着的格才去下一个站位（look 覆盖整盒，其余格换站位也不会变）。
            {:next, state} ->
              if Enum.any?(cells, &(state.skipped[&1] == :blocked)),
                do: visit(rest, state),
                else: finish(state)

            {:error, reason, _state} ->
              {:error, reason, @metrics}
          end
        else
          {:error, reason, _state} -> {:error, reason, @metrics}
        end

      {:error, reason, state} when reason in @unreachable ->
        visit(rest, state)

      {:error, reason, _state} ->
        {:error, reason, @metrics}
    end
  end

  defp finish(%{reached: false}), do: {:error, :unreachable, @metrics}

  defp finish(state) do
    case check(state) do
      {:done, state} -> done(state)
      {:more, _state} -> {:error, :exhausted, @metrics}
      {:error, reason, _state} -> {:error, reason, @metrics}
    end
  end

  defp done(state),
    do:
      {:ok,
       %{
         mined: state.mined,
         gained: state.gained,
         skipped: map_size(state.skipped),
         metrics: @metrics
       }}

  # 余额核对：增量够了 → done；不够按差额重估还要挖的格数。
  defp check(state) do
    with {:ok, %{balances: balances}, state} <- call(state, %{verb: :query_balances}) do
      gained = Enum.find(balances, &(&1.material == state.material)).balance - state.start
      state = %{state | gained: gained}

      if gained >= state.units,
        do: {:done, state},
        else: {:more, %{state | need: ceil((state.units - gained) / state.cost)}}
    end
  end

  # —— 逐格 ——

  defp dig([], _eye, state), do: {:next, state}

  defp dig([cell | rest], eye, state) do
    case mine(cell, eye, state) do
      {:mined, state} ->
        state = %{
          state
          | mined: state.mined + 1,
            need: state.need - 1,
            skipped: Map.delete(state.skipped, cell)
        }

        if state.need > 0 do
          dig(rest, eye, state)
        else
          case check(state) do
            {:more, state} -> dig(rest, eye, state)
            other -> other
          end
        end

      {kind, state} when kind in [:blocked, :foreign] ->
        dig(rest, eye, %{state | skipped: Map.put(state.skipped, cell, kind)})

      {:error, _, _} = error ->
        error
    end
  end

  defp mine(cell, eye, state) do
    micro = cell |> Tuple.to_list() |> Enum.map(&(&1 * Spatial.micro_resolution())) |> List.to_tuple()
    direction = WorldRequest.aim(eye, %{granularity: 0, micro: micro})

    case probe(state, direction) do
      {:ok, %{granularity: 0, micro: ^micro, owner: {0, 0}} = hit, state} -> strike(cell, hit, direction, state)
      {:ok, %{granularity: 0, micro: ^micro}, state} -> {:foreign, state}
      {:ok, _other, state} -> {:blocked, state}
      {:error, :no_target, state} -> {:blocked, state}
      {:error, _, _} = error -> error
    end
  end

  defp strike(cell, hit, direction, state) do
    state = pace(state)

    case call(state, %{verb: :use_tool, tool_id: state.tool, direction: direction, target: hit}) do
      {:ok, _, state} -> again(cell, hit, direction, state)
      {:error, :tool_cooldown, state} -> strike(cell, hit, direction, state)
      {:error, :stale_target, state} -> again(cell, hit, direction, state)
      {:error, reason, state} when reason in @blocked -> {:blocked, state}
      {:error, _, _} = error -> error
    end
  end

  # 每击之后再探测：仍是同一身份就再击；命中变了或 no_target 时，以这一格的权威内容判定是否挖掉
  # （命中变了不等于挖掉：眼点挪动、别的东西挡进射线也会让命中变化）。
  defp again(cell, hit, direction, state) do
    case probe(state, direction) do
      {:ok, next, state} ->
        if identity(next) == identity(hit),
          do: strike(cell, next, direction, state),
          else: settled(cell, state)

      {:error, :no_target, state} ->
        settled(cell, state)

      {:error, _, _} = error ->
        error
    end
  end

  # 这一格已是空气 = 挖掉；否则这次没打到它，留给下一个站位。
  defp settled(cell, state) do
    case call(state, %{verb: :look, min: cell, max: cell}) do
      {:ok, %{probe_occupancy: [%{material: 0, refined: false}]}, state} -> {:mined, state}
      {:ok, _, state} -> {:blocked, state}
      {:error, _, _} = error -> error
    end
  end

  defp probe(state, direction),
    do: call(state, %{verb: :probe_toward, tool_id: state.tool, direction: direction})

  defp identity(target), do: Map.take(target, [:granularity, :micro, :incarnation, :owner, :material])

  # 两击之间至少隔工具间隔：权威按同一间隔做 GCRA，这里只是不去撞它（撞上 tool_cooldown 也会再等一个间隔）。
  defp pace(%{last_hit: nil} = state), do: %{state | last_hit: now()}

  defp pace(state) do
    wait = state.last_hit + state.interval_ms - now()
    if wait > 0, do: Process.sleep(wait)
    %{state | last_hit: now()}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp call(state, command) do
    step = state.step + 1
    state = %{state | step: step}
    Body.command(state.body, Map.put(command, :id, {:skill, state.call, step}))

    receive do
      {:outcome, %{id: ^step, status: :done, data: data}} -> {:ok, data, state}
      {:outcome, %{id: ^step} = outcome} -> {:error, outcome.reason || outcome.status, state}
    after
      Skill.body_timeout() -> {:error, :body_timeout, state}
    end
  end
end
