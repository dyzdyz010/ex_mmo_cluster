defmodule GateServer.Npc.Brain.Builder do
  @moduledoc """
  全局系统功能：混合决策后端——建设者。三层分工：

    * 规划归 LLM：只问一次，要一份结构化蓝图（`GateServer.Npc.Blueprint` 的操作表），不让它逐格下命令；
    * 施工归代码：走到站位、`look` 对账、自下而上逐格放，顺利时一次模型都不问；
    * 异常归 Jev（`GateServer.Npc.Jev`）：被拒、够不着、世界与蓝图不符时问它“现在该干什么”，拿不准或判定计划走不下去才回头找 LLM 重新规划。

  长期记忆（`profile.memory`，生产里是 `DataService.NpcMemory`）：当前蓝图按 cid 存着，Body 重启后接着盖；进度不存——
  世界是真值，每次都拿 `look` 的结果现算还差哪些格。完工、缺料停工等经历写进 journal。

  `step/2` 是纯状态机（事件 → 新状态 + 效果表），进程壳只负责执行效果：发命令、问模型、读写记忆。

  profile:
      %{cid:, goal: "自然语言目标（含坐标与材料 id）", tool_id: 放置用的工具,
        planner: LLM endpoint, scheduler: Jev endpoint, activities: 显式 Jev 活动 profile,
        memory: 模块（get/3、put/4、delete/3、journal/3）}
  """
  @behaviour GateServer.Npc.Brain
  require Logger
  alias GateServer.Npc.{Blueprint, Jev}
  alias GateServer.Npc.Brain.Llm

  @doc "荒野逐格施工的活动数据；调用方显式放进 profile.activities，Jev 不持有默认活动。"
  def activity_profile do
    %{
      instructions:
        "What should the builder NPC do right now? If several apply, the priority is: move_to_safety first, then " <>
          "respond_to_player, then replan, then fetch_material, and continue_building only if none of the others apply.",
      activities: %{
        "continue_building" => "Nothing is wrong: keep executing the current building plan.",
        "fetch_material" => "Stop building and go gather more building material.",
        "respond_to_player" => "Pause work and respond to a player who is addressing the NPC.",
        "move_to_safety" => "Get away from an immediate physical danger.",
        "replan" => "The world contradicts the blueprint, or the same step failed repeatedly, so the plan cannot proceed as written."
      }
    }
  end

  # 蓝图被退回重画、异常后重新规划，合计最多这么多次；再不行就停工记一笔，不无限花钱。
  @plans 3

  # ---------------------------------------------------------------- 纯状态机

  @doc "`ops` 是记忆里的蓝图（没有就是 nil）。"
  def new(profile, ops) do
    cells =
      case ops && Blueprint.cells(ops) do
        {:ok, cells} -> cells
        _ -> nil
      end

    %{
      goal: profile.goal,
      tool_id: profile.tool_id,
      phase: :start,
      cells: cells,
      todo: [],
      # 当前这一格还没试过的站位；nil = 这一格还没算过（先从原地试放）。
      stands: nil,
      problem: nil,
      world: %{},
      looks: [],
      position: nil,
      balances: nil,
      waiting: nil,
      next_id: 1,
      plans: 0,
      occupied_at: nil
    }
  end

  @doc "事件：Body 的 `{:observation, _}` / `{:outcome, _}`，以及壳送回的 `{:blueprint, ops}`、`{:plan_failed, reason}`、`{:verdict, v}`。"
  def step(state, {:observation, %{self: %{position: position}, balances: balances}}) do
    state = %{state | position: position, balances: balances || state.balances}
    if state.phase == :start and state.waiting == nil, do: command(%{state | phase: :balances}, %{verb: :query_balances}), else: {state, []}
  end

  def step(%{waiting: id} = state, {:outcome, %{id: id} = outcome}), do: outcome(%{state | waiting: nil}, outcome)
  def step(state, {:outcome, _}), do: {state, []}

  def step(%{phase: :planning} = state, {:blueprint, ops}) do
    case Blueprint.cells(ops) do
      {:ok, cells} -> approach(%{state | cells: cells}, [{:remember, ops}])
      :error -> plan(state, "The previous blueprint was rejected: malformed operations, empty, or more than 2000 cells.")
    end
  end

  def step(%{phase: :planning} = state, {:plan_failed, reason}), do: plan(state, "The previous planning request failed: #{inspect(reason)}.")

  def step(%{phase: :triage} = state, {:verdict, {:act, :continue_building}}), do: survey(state, [])

  def step(%{phase: :triage} = state, {:verdict, {:act, :fetch_material}}),
    do: idle(state, "Stopped building: not enough material for the blueprint.")

  def step(%{phase: :triage} = state, {:verdict, {:escalate, _}}), do: plan(%{state | cells: nil}, state.problem)
  def step(%{phase: :triage} = state, {:verdict, other}), do: idle(state, "Stopped building: #{inspect(other)}.")
  def step(state, _event), do: {state, []}

  # 余额读到了（取这条结果里的，不等下一次 Observation）：有蓝图就去工地，没有就请规划者画。
  defp outcome(%{phase: :balances} = state, outcome) do
    state = %{state | balances: (outcome.data || %{})[:balances] || state.balances}
    if state.cells, do: approach(state, []), else: plan(state, nil)
  end

  # 走到站位（到不了就换下一个；都到不了 = 计划走不下去）。
  defp outcome(%{phase: :approach} = state, %{status: :done}), do: survey(state, [])

  defp outcome(%{phase: :approach, stands: [_ | rest]} = state, %{reason: reason}) do
    case rest do
      [] -> triage(state, "Movement to the building site failed with the reason: #{reason}. No standing spot around the site can be reached.")
      [next | _] -> command(%{state | stands: rest}, move(next))
    end
  end

  # 对账：一层一个 look，攒齐了再算还差哪些格。
  defp outcome(%{phase: :survey, looks: looks} = state, %{status: :done, data: %{probe_occupancy: cells}}) do
    world = for %{cell: [x, y, z], material: material} <- cells, into: state.world, do: {{x, y, z}, material}

    case looks do
      [next | rest] -> command(%{state | world: world, looks: rest}, next)
      [] -> reconciled(%{state | world: world}, Blueprint.remaining(state.cells, world))
    end
  end

  defp outcome(%{phase: :survey} = state, %{reason: reason}),
    do: triage(state, "Looking at the building site was rejected with the reason: #{inspect(reason)}.")

  # 施工：放好了就下一格；够不着换站位；被占了重新对账（同一格连续两次 = 世界与蓝图不符）；其余交给调度。
  defp outcome(%{phase: :build, todo: [_ | rest]} = state, %{verb: :place, status: :done}),
    do: build(%{state | todo: rest, stands: nil, occupied_at: nil})

  defp outcome(%{phase: :build, todo: [{cell, _} | _]} = state, %{verb: :place, reason: :out_of_reach}) do
    case state.stands do
      [] -> triage(state, "The cell #{inspect(cell)} of the blueprint cannot be reached from any standing spot around the site.")
      [next | rest] -> command(%{state | stands: rest}, move(next))
    end
  end

  defp outcome(%{phase: :build, todo: [{cell, _} | _], occupied_at: cell} = state, %{verb: :place, reason: :occupied}),
    do: triage(state, "Placing a block at #{inspect(cell)} was rejected twice with the reason: occupied. The blueprint says that cell should be empty.")

  defp outcome(%{phase: :build, todo: [{cell, _} | _]} = state, %{verb: :place, reason: :occupied}), do: survey(%{state | occupied_at: cell}, [])

  defp outcome(%{phase: :build} = state, %{verb: :place, reason: :insufficient_material}),
    do: triage(state, "Material check by the game: not enough material for the next block of the blueprint. #{length(state.todo)} blocks are still missing.")

  defp outcome(%{phase: :build, todo: [{cell, _} | _]} = state, %{verb: :place, reason: reason}),
    do: triage(state, "Placing a block at #{inspect(cell)} was rejected with the reason: #{inspect(reason)}.")

  # 换站位的那一步走完（或走不到）：都回去再试放；走不到的站位已经从表里去掉了。
  defp outcome(%{phase: :build} = state, %{verb: :move_to}), do: build(state)
  defp outcome(state, _), do: {state, []}

  defp reconciled(state, %{todo: [], wrong: []}),
    do: idle(%{state | cells: nil}, "Finished building: #{map_size(state.cells)} blocks placed as the blueprint says. Goal was: #{state.goal}", [:forget])

  defp reconciled(state, %{wrong: [{cell, found, _} | _] = wrong}),
    do:
      triage(state, "You looked at the site: #{length(wrong)} cells of the blueprint are occupied by other material " <>
        "(for example #{inspect(cell)} holds material #{found}), which the blueprint did not account for.")

  defp reconciled(state, %{todo: todo}), do: build(%{state | todo: todo})

  defp build(%{todo: [{{x, y, z} = cell, material} | _]} = state) do
    stands = state.stands || Blueprint.stands(state.cells, cell)
    command(%{state | phase: :build, stands: stands}, %{verb: :place, coord: {x, y, z}, material: material, tool_id: state.tool_id})
  end

  defp build(%{todo: []} = state), do: survey(state, [])

  defp approach(state, effects) do
    {min, _} = Blueprint.bounds(state.cells)
    [first | _] = stands = Blueprint.stands(state.cells, min)
    {state, more} = command(%{state | phase: :approach, stands: stands}, move(first))
    {state, effects ++ more}
  end

  defp survey(state, effects) do
    {{x0, y0, z0}, {x1, y1, z1}} = Blueprint.bounds(state.cells)
    [first | rest] = for y <- y0..y1, do: %{verb: :look, min: {x0, y, z0}, max: {x1, y, z1}}
    {state, more} = command(%{state | phase: :survey, world: %{}, looks: rest, stands: nil}, first)
    {state, effects ++ more}
  end

  defp plan(%{plans: @plans} = state, _note), do: idle(state, "Stopped: no usable blueprint after #{@plans} planning attempts. Goal was: #{state.goal}")

  defp plan(state, note) do
    request = %{goal: state.goal, position: state.position, balances: state.balances, note: note}
    {%{state | phase: :planning, plans: state.plans + 1, cells: nil}, [{:plan, request}]}
  end

  defp triage(state, problem), do: {%{state | phase: :triage, problem: problem}, [{:triage, problem}]}
  defp idle(state, entry, effects \\ []), do: {%{state | phase: :idle}, [{:journal, entry} | effects]}
  defp move({x, z}), do: %{verb: :move_to, position: {x, z}, tolerance: 0.5}

  defp command(state, command) do
    id = state.next_id
    {%{state | waiting: id, next_id: id + 1}, [{:command, Map.put(command, :id, id)}]}
  end

  # ---------------------------------------------------------------- 规划请求（LLM，OpenAI Responses 线格式）

  @doc "一次规划请求体：只有一个工具 `submit_blueprint`，必须调用。"
  def plan_body(endpoint, %{goal: goal, position: position, balances: balances, note: note}) do
    %{
      model: endpoint.model,
      instructions:
        "You plan voxel edits. Coordinates are integer cells, 1 cell = 1 meter, Y is up. " <>
          "Answer by calling submit_blueprint once. The blueprint is a list of operations applied in order, each on an inclusive box: " <>
          "walls (only the four vertical sides of the box: the outer ring on every layer, no floor and no ceiling), " <>
          "fill (solid box of one material) and clear (remove cells). Later operations override earlier ones. " <>
          "The external goal defines the shape, features, materials and site. Keep the plan within its stated footprint and under 400 cells.",
      input:
        Jason.encode!(%{
          goal: goal,
          npc_position: position && Tuple.to_list(position),
          backpack_cells: balances && for(%{balance: b, cost: c, material: m} when b > 0 <- balances, do: %{material: m, cells: div(b, c)}),
          note: note
        }),
      tools: [
        %{
          type: "function",
          name: "submit_blueprint",
          description: "Submit the complete blueprint.",
          parameters: %{
            type: "object",
            properties: %{
              ops: %{
                type: "array",
                items: %{
                  type: "object",
                  properties: %{
                    op: %{type: "string", enum: ["walls", "fill", "clear"]},
                    min: %{type: "array", items: %{type: "integer"}, minItems: 3, maxItems: 3},
                    max: %{type: "array", items: %{type: "integer"}, minItems: 3, maxItems: 3},
                    material: %{type: "integer"}
                  },
                  required: ["op", "min", "max"],
                  additionalProperties: false
                }
              }
            },
            required: ["ops"],
            additionalProperties: false
          }
        }
      ],
      tool_choice: "required",
      parallel_tool_calls: false,
      reasoning: %{effort: Map.get(endpoint, :effort, "low")},
      store: false
    }
  end

  @doc "应答 → 蓝图操作表（`{:ok, ops}` / `:error`）。"
  def plan_ops(%{"output" => output}) do
    with %{"arguments" => arguments} <- Enum.find(output, &(&1["type"] == "function_call" and &1["name"] == "submit_blueprint")),
         {:ok, %{"ops" => ops}} when is_list(ops) <- Jason.decode(arguments) do
      {:ok, ops}
    else
      _ -> :error
    end
  end

  # ---------------------------------------------------------------- 进程壳：执行效果

  @impl true
  def init(profile) do
    body = self()
    spawn_link(fn -> loop(start(profile), profile, body) end)
  end

  @impl true
  def handle_event(event, pid) do
    send(pid, event)
    {[], pid}
  end

  defp start(profile) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    plan = profile.memory.get(profile.cid, "plan", "current")
    new(profile, plan && plan["ops"])
  end

  defp loop(state, profile, body) do
    event =
      receive do
        event -> event
      end

    {state, effects} = step(state, event)
    for effect <- effects, do: perform(effect, state, profile, body)
    loop(state, profile, body)
  end

  @doc "用调用方活动数据调度荒野施工异常，返回原状态机认识的决定；不启动进程。"
  def triage_verdict(profile, problem) do
    send = Map.get(profile, :request, &Llm.request/2)
    situation = "You are a builder NPC in a voxel world, executing a blueprint. " <> problem
    Logger.info("npc_builder_triage cid=#{profile.cid} problem=#{problem}")

    verdict =
      case Jev.ask(profile.scheduler, profile.activities, situation, nil, send) do
        {:ok, {:act, "continue_building"}, _} -> {:act, :continue_building}
        {:ok, {:act, "fetch_material"}, _} -> {:act, :fetch_material}
        {:ok, {:act, "replan"}, _} -> {:escalate, :unexpected}
        {:ok, verdict, _} -> verdict
        # 调度模型问不到：交给规划者，不硬猜。
        {:error, _} -> {:escalate, :scheduler_unavailable}
      end

    Logger.info("npc_builder_verdict cid=#{profile.cid} verdict=#{inspect(verdict)}")
    verdict
  end


  defp perform({:command, command}, _state, _profile, body), do: GateServer.Npc.Body.command(body, command)

  defp perform({:plan, request}, _state, profile, _body) do
    owner = self()
    send = Map.get(profile, :request, &Llm.request/2)
    Logger.info("npc_builder_plan cid=#{profile.cid} note=#{inspect(request.note)}")

    spawn_link(fn ->
      answer =
        with {:ok, response} <- send.(profile.planner, plan_body(profile.planner, request)),
             {:ok, ops} <- plan_ops(response) do
          {:blueprint, ops}
        else
          other -> {:plan_failed, other}
        end

      send(owner, answer)
    end)
  end


  defp perform({:triage, problem}, _state, profile, _body) do
    owner = self()
    spawn_link(fn -> send(owner, {:verdict, triage_verdict(profile, problem)}) end)
  end

  defp perform({:remember, ops}, state, profile, _body),
    do: profile.memory.put(profile.cid, "plan", "current", %{"ops" => ops, "goal" => state.goal})

  defp perform(:forget, _state, profile, _body), do: profile.memory.delete(profile.cid, "plan", "current")

  defp perform({:journal, text}, state, profile, _body) do
    Logger.info("npc_builder_journal cid=#{profile.cid} #{text}")
    profile.memory.journal(profile.cid, text, state.position || {0, 0, 0})
  end
end
