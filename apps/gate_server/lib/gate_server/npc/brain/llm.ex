defmodule GateServer.Npc.Brain.Llm do
  @moduledoc """
  全局系统功能：LLM 决策后端（OpenAI Responses 线格式）。回调只把事件转给自己的进程，立刻返回；
  该进程在“没有在途命令且有新情况”时问一次模型，把模型的工具调用译成命令，用 `Body.command/2` 投回。
  每次请求无状态：目标 + 当前 Observation + 最近的 Outcome + 持久化经历。模型的输出是外部输入，合法性由 Body 与权威裁决。
  请求之间模型看不到自己上一次调用了什么，所以给它看的每条 Outcome 都附上当初那次调用（`command`）：
  只有 `{id, verb, status}` 时模型对不上“哪一格放好了”，实测会原地反复 look。
  `remember` / `recall` / `search_memory` 通过 NpcMemory 保存、读取与搜索长期记忆；每轮现读近期与相关内容。

  profile:
      %{goal: "自然语言目标", tools: %{tool_id => "用途"},   # 这个 NPC 带着的工具；模型只能从中选
        endpoint: %{url:, key:, model:, effort: 可选（思考强度，接口认的 "low" / "medium" / "high" 等，缺省 "low"）, cacertfile: 可选}}

  skills 是技能名到配置的 map；技能和记忆命令交给 Runtime，LLM 只等待最终 Outcome。
  Runtime 拥有可选中断策略、worker 与停止确认；本模块只拥有模型请求、工具解析和模型上下文。
  """
  @behaviour GateServer.Npc.Brain
  require Logger
  alias GateServer.Npc.{Memory, Skills, Context, Perception}

  @history 8
  # 两次请求的最小间隔（毫秒）：连续被拒时不空转打接口。
  @min_gap_ms 1_000

  @cell %{x: %{type: "integer"}, y: %{type: "integer"}, z: %{type: "integer"}}

  # 工具表随 profile 的工具带生成：tool_id 必填且只能取带着的 id，模型无从编造。
  defp tools(%{tools: belt} = profile) do
    tool_id = %{type: "integer", enum: Map.keys(belt), description: "用哪个工具，见输入里的 tools。"}

    [
      %{
        type: "function",
        name: "move_to",
        description:
          "走到水平坐标 (x, z)，自动寻路：会绕开障碍、按 self.body.move_to.max_step_macro 上台阶、从高处落下，但不会跳，也不进液体；单程水平不超过 32 米。" <>
            "同一处上下有几层能站时用 y 指定站立格（脚所在的那个空气格，整数）。走不通会被拒绝：no_path = 现在没有路，" <>
            "stuck = 路上被堵住了，再调用一次会按现在的世界重新找路。到达后才会再次询问。",
        parameters: %{
          type: "object",
          properties: %{x: %{type: "number"}, z: %{type: "number"}, y: %{type: "integer"}},
          required: ["x", "z"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "stop",
        description: "停下。",
        parameters: %{type: "object", properties: %{}, additionalProperties: false}
      },
      %{
        type: "function",
        name: "probe_toward",
        description:
          "从眼睛位置沿方向 (dx, dy, dz) 探测工具射程内实际命中的目标；没有目标会被拒绝。+X 是 (1,0,0)，+Z 是 (0,0,1)，Y 向上。",
        parameters: %{
          type: "object",
          properties: %{
            dx: %{type: "number"},
            dy: %{type: "number"},
            dz: %{type: "number"},
            tool_id: tool_id
          },
          required: ["dx", "dy", "dz", "tool_id"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "use_tool",
        description:
          "对最近一次 probe_toward 命中的目标使用工具（镐 = 攻击；挖掉的材料进自己的 balances）。有约 0.5 秒的间隔限制；一个目标通常要多次。" <>
            "给了 attachment_id 就改为对最近一次 inspect 列出的那件附件使用（电路安装 / 投料 / 开关的目标都是附件）。",
        parameters: %{
          type: "object",
          properties: %{tool_id: tool_id, attachment_id: %{type: "integer"}},
          required: ["tool_id"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "place",
        description: "花自己 balances 里的 material，在空气格 (x,y,z) 放一个实心格；格心要在眼睛的工具射程内。",
        parameters: %{
          type: "object",
          properties: Map.merge(@cell, %{material: %{type: "integer"}, tool_id: tool_id}),
          required: ["x", "y", "z", "material", "tool_id"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "scoop",
        description: "用液体盛取工具从格 (x,y,z) 盛起 material 液体，进自己的 balances。",
        parameters: %{
          type: "object",
          properties: Map.merge(@cell, %{material: %{type: "integer"}, tool_id: tool_id}),
          required: ["x", "y", "z", "material", "tool_id"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "pour",
        description: "用液体倾倒工具把自己 balances 里的 material 液体倒进格 (x,y,z)。",
        parameters: %{
          type: "object",
          properties: Map.merge(@cell, %{material: %{type: "integer"}, tool_id: tool_id}),
          required: ["x", "y", "z", "material", "tool_id"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "attach",
        description:
          "花 material 在实心格表面贴一件附件。kind 0 = 面片（axis 是法线轴）、1 = 棱条（axis 是走向）；axis 0/1/2 = X/Y/Z；" <>
            "size 1 或 8；(x,y,z) 是 micro 坐标（1 格 = 8 micro），size 8 时须是 8 的倍数。",
        parameters: %{
          type: "object",
          properties:
            Map.merge(@cell, %{
              kind: %{type: "integer"},
              axis: %{type: "integer"},
              size: %{type: "integer"},
              material: %{type: "integer"},
              tool_id: tool_id
            }),
          required: ["kind", "axis", "size", "x", "y", "z", "material", "tool_id"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "detach",
        description:
          "拆下 attachment_id 那件附件，材料退回 balances；kind / axis / (x,y,z) / material 要与它一致。",
        parameters: %{
          type: "object",
          properties:
            Map.merge(@cell, %{
              kind: %{type: "integer"},
              axis: %{type: "integer"},
              material: %{type: "integer"},
              attachment_id: %{type: "integer"},
              tool_id: tool_id
            }),
          required: ["kind", "axis", "x", "y", "z", "material", "attachment_id", "tool_id"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "prefab",
        description:
          "预制件。op = place：以 micro 坐标 (x,y,z)（1 格 = 8 micro）为锚点、orientation 0–23 放置 definition；" <>
            "remove：拆掉 instance；replace：把 instance 换成 definition。definition 是 64 位十六进制 id，instance 是 [birth, occurrence]。",
        parameters: %{
          type: "object",
          properties:
            Map.merge(@cell, %{
              op: %{type: "string", enum: ["place", "remove", "replace"]},
              definition: %{type: "string"},
              orientation: %{type: "integer"},
              instance: %{type: "array", items: %{type: "integer"}}
            }),
          required: ["op"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "say",
        description: "对周围说一句话。",
        parameters: %{
          type: "object",
          properties: %{text: %{type: "string"}},
          required: ["text"],
          additionalProperties: false
        }
      },
      %{
        type: "function",
        name: "query_balances",
        description: "读取自己的背包余额（balances 为 null 时先调用它）。",
        parameters: %{type: "object", properties: %{}, additionalProperties: false}
      },
      %{
        type: "function",
        name: "wait",
        description: "什么都不做，seconds 秒后再被询问（1–300）。目标已完成或暂时无事可做时用它，不要反复调用 stop。",
        parameters: %{
          type: "object",
          properties: %{seconds: %{type: "number"}},
          required: ["seconds"],
          additionalProperties: false
        }
      }
    ] ++ Perception.tools() ++ Memory.tools() ++ Skills.tools(profile)
  end

  @impl true
  def init(profile) do
    body = self()
    spawn_link(fn -> loop(start(profile, body)) end)
  end

  @impl true
  def handle_event(event, pid) do
    send(pid, event)
    {[], pid}
  end

  @doc """
  把一次 Responses 应答里的工具调用译成命令；`probe` 是最近一次成功探测 `%{direction:, target:}`，
  `things` 是最近一次 inspect 的附件身份（attachment_id => 目标）。
  """
  def commands(
        response,
        probe,
        things,
        next_id,
        profile \\ %{skills: %{design: %{}, build: %{}, wilderness: %{}}}
      )

  def commands(%{"output" => output}, probe, things, next_id, profile) do
    output
    |> Enum.filter(&(&1["type"] == "function_call"))
    |> Enum.with_index(next_id)
    |> Enum.map(fn {call, id} ->
      args = Jason.decode!(call["arguments"])

      case call["name"] do
        "move_to" ->
          move = %{id: id, verb: :move_to, position: {args["x"], args["z"]}, tolerance: 0.5}
          if args["y"], do: Map.put(move, :y, args["y"]), else: move

        "stop" ->
          %{id: id, verb: :stop}

        "probe_toward" ->
          %{id: id, verb: :probe_toward, tool_id: args["tool_id"], direction: unit(args)}

        "look" ->
          %{
            id: id,
            verb: :look,
            min: {args["x0"], args["y0"], args["z0"]},
            max: {args["x1"], args["y1"], args["z1"]}
          }

        name when name in ["place", "scoop", "pour"] ->
          %{
            id: id,
            verb: %{"place" => :place, "scoop" => :scoop, "pour" => :pour}[name],
            coord: {args["x"], args["y"], args["z"]},
            material: args["material"],
            tool_id: args["tool_id"]
          }

        "query_balances" ->
          %{id: id, verb: :query_balances}

        "inspect" ->
          %{id: id, verb: :inspect}

        "say" ->
          %{id: id, verb: :say, text: args["text"]}

        # 附件按身份寻址、不经射线；direction 只需是单位向量。
        "use_tool" when is_map_key(args, "attachment_id") ->
          %{
            id: id,
            verb: :use_tool,
            tool_id: args["tool_id"],
            direction: {1.0, 0.0, 0.0},
            target: things[args["attachment_id"]]
          }

        name when name in ["attach", "detach"] ->
          %{
            id: id,
            verb: %{"attach" => :attach, "detach" => :detach}[name],
            kind: args["kind"],
            axis: args["axis"],
            size: args["size"] || 1,
            anchor: {args["x"], args["y"], args["z"]},
            material: args["material"],
            attachment_id: args["attachment_id"] || 0,
            tool_id: args["tool_id"]
          }

        "prefab" ->
          %{
            id: id,
            verb:
              %{
                "place" => :prefab_place,
                "remove" => :prefab_remove,
                "replace" => :prefab_replace
              }[args["op"]],
            definition_id: hex(args["definition"]),
            anchor: {args["x"], args["y"], args["z"]},
            orientation: args["orientation"],
            instance_id: List.to_tuple(args["instance"] || [])
          }

        # 只属于本 adapter：不发给 Body。
        name when name in ["remember", "recall", "search_memory"] ->
          Memory.command(name, args, id)

        # 只属于本 adapter：不发给 Body，挂起询问。
        "wait" ->
          %{id: id, verb: :wait, seconds: args["seconds"]}

        "use_tool" ->
          %{
            id: id,
            verb: :use_tool,
            tool_id: args["tool_id"],
            direction: probe && probe.direction,
            target: probe && probe.target
          }

        name ->
          Skills.command(name, args, id, profile) || %{id: id, verb: :unknown_tool}
      end
    end)
  end

  @doc "一次应答里的工具调用原样（id => %{tool:, args:}），编号方式与 `commands/4` 相同；Outcome 回来时附给模型看。"
  def calls(%{"output" => output}, next_id) do
    for {call, id} <-
          output |> Enum.filter(&(&1["type"] == "function_call")) |> Enum.with_index(next_id),
        into: %{},
        do: {id, %{tool: call["name"], args: Jason.decode!(call["arguments"])}}
  end

  defp unit(%{"dx" => dx, "dy" => dy, "dz" => dz})
       when is_number(dx) and is_number(dy) and is_number(dz) do
    length = :math.sqrt(dx * dx + dy * dy + dz * dz)
    if length > 0, do: {dx / length, dy / length, dz / length}, else: {dx, dy, dz}
  end

  defp unit(_), do: nil

  defp hex(text) when is_binary(text) do
    case Base.decode16(text, case: :mixed) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp hex(_), do: nil

  defp start(profile, body) do
    Process.flag(:trap_exit, true)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    %{
      body: body,
      profile: profile,
      memory: Map.get(profile, :memory, DataService.NpcMemory),
      request: Map.get(profile, :request, &GateServer.Npc.Http.request/2),
      observation: nil,
      outcomes: [],
      # 发出过但还没有 Outcome 的探测方向：id => direction。
      probes: %{},
      probe: nil,
      # 最近一次 inspect 的附件身份：attachment_id => 目标。
      things: %{},
      # 发出去还没有 Outcome 的调用：id => %{tool:, args:}。
      calls: %{},
      dirty: true,
      asking: false,
      request_pid: nil,
      # monotonic_time 可以为负，不能用 0 当“很久以前”。
      asked_ms: System.monotonic_time(:millisecond) - @min_gap_ms,
      next_id: 1
    }
  end

  defp loop(state) do
    state =
      receive do
        {:observation, observation} ->
          %{state | observation: observation}

        {:outcome, outcome} ->
          record_outcome(state, outcome)

        {:heard, _message} ->
          %{state | dirty: true}

        {:EXIT, body, _reason} when body == state.body ->
          exit(:shutdown)

        {:EXIT, pid, reason} when pid == state.request_pid and reason != :normal ->
          exit(reason)

        {:EXIT, _pid, _reason} ->
          state

        {:answer, {:ok, response}} ->
          all = commands(response, state.probe, state.things, state.next_id, state.profile)

          {waits, commands} = Enum.split_with(all, &(&1.verb == :wait))

          Logger.info("npc_llm_decision #{inspect(all, limit: :infinity)}")
          for command <- commands, do: GateServer.Npc.Body.command(state.body, command)

          # 每次询问都要花钱：模型说等多久就挂起多久（夹在 1–300 秒），到点再标记有新情况。
          for %{seconds: seconds} <- waits,
              is_number(seconds),
              do: Process.send_after(self(), :wake, round(min(300, max(1, seconds)) * 1_000))

          probes =
            for %{verb: :probe_toward, id: id, direction: direction} <- commands,
                into: state.probes,
                do: {id, direction}

          sent = Map.take(calls(response, state.next_id), Enum.map(commands, & &1.id))

          state = %{
            state
            | asking: false,
              request_pid: nil,
              probes: probes,
              calls: Map.merge(state.calls, sent),
              next_id: state.next_id + length(all)
          }

          state

        :wake ->
          %{state | dirty: true}

        {:answer, {:error, reason}} ->
          Logger.warning("npc_llm_request_failed reason=#{inspect(reason)}")
          %{state | asking: false, request_pid: nil, dirty: true}
      end

    loop(ask(state))
  end

  defp record_outcome(state, outcome) do
    state = remember_probe(state, outcome)
    position = state.observation && state.observation.self.position
    {call, calls} = Map.pop(state.calls, outcome.id)
    outcome = if call, do: Map.put(outcome, :command, call), else: outcome

    %{
      state
      | calls: calls,
        dirty: true,
        outcomes: Enum.take(Perception.project(outcome, state.outcomes, position), @history)
    }
  end

  defp remember_probe(state, %{verb: :probe_toward, id: id} = outcome) do
    {direction, probes} = Map.pop(state.probes, id)

    probe =
      if outcome.status == :done,
        do: %{direction: direction, target: outcome.data},
        else: state.probe

    %{state | probes: probes, probe: probe}
  end

  defp remember_probe(state, %{verb: :inspect, status: :done, data: %{property_states: rows}}) do
    things =
      for %{granularity: 3, incarnation: id} = row <- rows, into: %{} do
        {id, Map.take(row, [:granularity, :micro, :incarnation, :owner, :material])}
      end

    %{state | things: things}
  end

  defp remember_probe(state, _), do: state

  # 有新情况、没有在途命令、没有在途请求、且过了最小间隔，才问一次。
  defp ask(
         %{dirty: true, asking: false, calls: calls, observation: %{pending: []} = observation} =
           state
       ) do
    now = System.monotonic_time(:millisecond)

    if map_size(calls) == 0 and now - state.asked_ms >= @min_gap_ms do
      owner = self()

      query =
        state.profile.goal <>
          " " <> inspect(Enum.take(state.outcomes, 1), limit: 20, printable_limit: 300)

      experiences = Memory.context(state.memory, observation.self.entity_id, query)
      body = body(state.profile, observation, state.outcomes, experiences)

      pid =
        spawn_link(fn -> send(owner, {:answer, state.request.(state.profile.endpoint, body)}) end)

      %{state | dirty: false, asking: true, request_pid: pid, asked_ms: now}
    else
      state
    end
  end

  defp ask(state), do: state

  @doc "一次请求体：目标、当前 Observation、最近 Outcome（旧在前），要求恰好一次工具调用。"
  def body(profile, observation, outcomes, experiences \\ []) do
    %{
      model: profile.endpoint.model,
      instructions:
        "你控制体素世界里的一个 NPC。每次只调用一个工具来推进目标；不要输出文字。" <>
          "坐标单位米，Y 向上，水平面是 X/Z。上一步的结果在 outcomes 里：status=rejected 表示权威拒绝，reason 是原因。" <>
          "眼睛在 self.position 上方 0.6 米，探测与射程都从眼睛算；balances 是你的背包（每种 material 还能放几个整格）。" <>
          "记忆不是世界真值；每次动手前先用 look/inspect 核对当前位置与目标。" <>
          "experiences 是近期经历；memories 是每轮检索的相关记忆和近期笔记，带时间与来源；memory_error 表示读取失败。" <>
          "新获知的约定、计划、重要经验用 remember 保存或更新；recall 按键读，search_memory 按内容找，中文可换短关键词。" <>
          "能力以本次 tools 参数表为准；设计技能可自行 look/inspect 和读写记忆，发布后用 build 才会改变世界。",
      input:
        Jason.encode!(
          %{
            goal: profile.goal,
            coordinates: Context.coordinates(),
            self: Context.plain(observation.self),
            tools: profile.tools,
            # 背包：每种材料还能放几个整格；null = 还没读过。
            balances:
              observation.balances &&
                for(
                  %{balance: balance} = b when balance > 0 <- observation.balances,
                  do: %{material: b.material, cells: balance / b.cost}
                ),
            entities: Enum.map(observation.entities, &Context.plain/1),
            outcomes: outcomes |> Enum.reverse() |> Enum.map(&Context.plain/1)
          }
          |> Map.merge(memory_input(experiences))
        ),
      tools: tools(profile),
      tool_choice: "required",
      parallel_tool_calls: false,
      reasoning: %{effort: Map.get(profile.endpoint, :effort, "low")},
      store: false
    }
  end

  defp memory_input(events) when is_list(events), do: %{experiences: Context.plain(events)}
  defp memory_input(%{} = context), do: Context.plain(context)
end
