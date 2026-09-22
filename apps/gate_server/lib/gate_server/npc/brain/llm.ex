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

  启用长任务时另给 `skills`、`scheduler`、`activities` 和 `continue_activity`：
  skills 是技能名到配置的 map；activities 的英文判据传给 Jev，continue_activity 是继续当前技能的选项。
  技能 worker 不阻塞 Body；父大脑等待一次最终结果，运行期间以独立 Jev 请求判断中断。
  """
  @behaviour GateServer.Npc.Brain
  require Logger
  alias GateServer.Npc.{Memory, Skills, Jev, Context, Perception}

  @history 8
  # inspect 在建成区能有几百行：只把离自己最近的这么多件给模型，总数另报。
  @nearest 24
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
        description: "从眼睛位置沿方向 (dx, dy, dz) 探测工具射程内实际命中的目标；没有目标会被拒绝。+X 是 (1,0,0)，+Z 是 (0,0,1)，Y 向上。",
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
        description:
          "花自己 balances 里的 material，在空气格 (x,y,z) 放一个实心格；格心要在眼睛的工具射程内。",
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
        description: "拆下 attachment_id 那件附件，材料退回 balances；kind / axis / (x,y,z) / material 要与它一致。",
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
  def commands(%{"output" => output}, probe, things, next_id) do
    output
    |> Enum.filter(&(&1["type"] == "function_call"))
    |> Enum.with_index(next_id)
    |> Enum.map(fn {call, id} ->
      args = Jason.decode!(call["arguments"])

      case call["name"] do
        name when name in ["design", "build", "wilderness"] ->
          Skills.command(name, args, id)

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
            verb: %{"place" => :prefab_place, "remove" => :prefab_remove, "replace" => :prefab_replace}[args["op"]],
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
      end
    end)
  end

  @doc "一次应答里的工具调用原样（id => %{tool:, args:}），编号方式与 `commands/4` 相同；Outcome 回来时附给模型看。"
  def calls(%{"output" => output}, next_id) do
    for {call, id} <- output |> Enum.filter(&(&1["type"] == "function_call")) |> Enum.with_index(next_id),
        into: %{},
        do: {id, %{tool: call["name"], args: Jason.decode!(call["arguments"])}}
  end

  defp unit(%{"dx" => dx, "dy" => dy, "dz" => dz}) when is_number(dx) and is_number(dy) and is_number(dz) do
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
      request: Map.get(profile, :request, &__MODULE__.request/2),
      observation: nil,
      outcomes: [],
      # 发出过但还没有 Outcome 的探测方向：id => direction。
      probes: %{},
      probe: nil,
      # 最近一次 inspect 的附件身份：attachment_id => 目标。
      things: %{},
      # 发出去还没有 Outcome 的调用：id => %{tool:, args:}。
      calls: %{},
      skill: nil,
      heard: false,
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
          if state.skill && state.skill.command.skill != :design && state.skill.cancelling == nil,
            do: send(state.skill.pid, {:observation, observation})
          %{state | observation: observation}

        {:outcome, %{id: {:skill, id, step}} = outcome} ->
          case state.skill do
            %{command: %{id: ^id}, cancelling: nil} = active ->
              send(active.pid, {:outcome, %{outcome | id: step}})
              state
            %{command: %{id: ^id}, cancelling: reason} when step == :stop ->
              reason = if outcome.status == :done, do: reason,
                else: {:stop_failed, outcome.status, outcome.reason}
              finish_skill(state, {:error, reason, %{request_count: nil, jev_request_count: nil}})
            _ -> state
          end

        {:outcome, outcome} ->
          record_outcome(state, outcome)

        {:heard, _message} ->
          if state.skill, do: send(self(), {:skill_check, state.skill.command.id})
          %{state | heard: true, dirty: true}

        {:skill_finished, id, result} ->
          case state.skill do
            %{command: %{id: ^id}, cancelling: nil} -> finish_skill(state, result)
            _ -> state
          end

        {:skill_check, id} ->
          check_skill(state, id)

        {:skill_verdict, id, verdict} ->
          decide_skill(state, id, verdict)

        {:DOWN, ref, :process, _pid, reason} ->
          case state.skill do
            %{ref: ^ref, cancelling: nil} ->
              finish_skill(state, {:error, {:skill_failed, exit_kind(reason)}, %{request_count: nil, jev_request_count: nil}})
            %{ref: ^ref} = active ->
              # 等技能退出，最后一条原子命令已发完，再排入停止命令。
              GateServer.Npc.Body.command(state.body, %{id: {:skill, active.command.id, :stop}, verb: :stop})
              state
            %{jev_ref: ^ref, cancelling: nil} when reason != :normal ->
              interrupt_skill(state, :scheduler_unavailable)
            _ -> state
          end

        {:EXIT, body, _reason} when body == state.body ->
          if state.skill, do: Process.exit(state.skill.pid, :shutdown)
          exit(:shutdown)

        {:EXIT, pid, reason} when pid == state.request_pid and reason != :normal ->
          exit(reason)

        {:EXIT, _pid, _reason} -> state

        {:answer, {:ok, response}} ->
          all = commands(response, state.probe, state.things, state.next_id)
          {local, commands} = Enum.split_with(all, &(&1.verb in [:wait, :remember, :recall, :search_memory]))
          {skills, body_commands} = Enum.split_with(commands, &(&1.verb == :skill))

          {memories, waits} = Enum.split_with(local, &(&1.verb != :wait))

          Logger.info("npc_llm_decision #{inspect(local ++ commands, limit: :infinity)}")
          for command <- body_commands, do: GateServer.Npc.Body.command(state.body, command)

          # 每次询问都要花钱：模型说等多久就挂起多久（夹在 1–300 秒），到点再标记有新情况。
          for %{seconds: seconds} <- waits, is_number(seconds),
            do: Process.send_after(self(), :wake, round(min(300, max(1, seconds)) * 1_000))

          probes =
            for %{verb: :probe_toward, id: id, direction: direction} <- commands,
                into: state.probes,
                do: {id, direction}

          sent = Map.take(calls(response, state.next_id), Enum.map(commands ++ memories, & &1.id))
          state = %{state | asking: false, request_pid: nil, probes: probes, calls: Map.merge(state.calls, sent), next_id: state.next_id + length(all)}

          state = Enum.reduce(memories, state, fn command, state ->
            actor = state.observation.self
            outcome = Memory.execute(state.memory, actor.entity_id, actor.position, command)
            record_outcome(state, outcome)
          end)
          Enum.reduce(skills, state, &start_skill(&2, &1))

        :wake ->
          %{state | dirty: true}

        {:answer, {:error, reason}} ->
          Logger.warning("npc_llm_request_failed reason=#{inspect(reason)}")
          %{state | asking: false, request_pid: nil, dirty: true}
      end

    loop(ask(state))
  end

  defp start_skill(%{skill: nil} = state, command) do
    active = Skills.start(state.body, command, state.profile, state.observation)
    timer = Process.send_after(self(), {:skill_check, command.id}, 10_000)
    %{state | skill: Map.merge(active, %{timer: timer, cancelling: nil, jev_ref: nil, jev_pid: nil, jev_requests: 0})}
  end
  defp start_skill(state, command),
    do: record_outcome(state, %{id: command.id, verb: command.skill, status: :rejected, reason: :skill_busy, data: nil})

  defp check_skill(%{skill: %{command: %{id: id}, cancelling: nil, jev_ref: nil} = active} = state, id) do
    parent = self()
    # 不把用户目标或聊天原文塞进 Jev；只给英文事实和结构化权威观察。
    situation = "An NPC is executing the #{active.command.skill} skill. " <>
      "A player is addressing the NPC: #{state.heard}. Current observation: " <>
      Jason.encode!(plain(Map.take(state.observation, [:self, :entities, :balances, :pending])))
    {pid, ref} = :erlang.spawn_opt(fn ->
      result = Jev.ask(state.profile.scheduler, state.profile.activities, situation, nil, state.request)
      send(parent, {:skill_verdict, id, result})
    end, [:link, :monitor])
    %{state | skill: %{active | jev_ref: ref, jev_pid: pid, jev_requests: active.jev_requests + 1}}
  end
  defp check_skill(state, _), do: state

  defp decide_skill(%{skill: %{command: %{id: id}, cancelling: nil} = active} = state, id, verdict) do
    Process.demonitor(active.jev_ref, [:flush])
    state = %{state | skill: %{active | jev_ref: nil, jev_pid: nil}}
    case verdict do
      {:ok, {:act, activity}, _} when activity == state.profile.continue_activity ->
        Process.cancel_timer(active.timer)
        timer = Process.send_after(self(), {:skill_check, id}, 10_000)
        %{state | skill: %{state.skill | timer: timer}}
      {:ok, {:act, activity}, _} -> interrupt_skill(state, {:interrupted, activity})
      {:ok, other, _} -> interrupt_skill(state, {:interrupted, other})
      {:error, _} -> interrupt_skill(state, :scheduler_unavailable)
    end
  end
  defp decide_skill(state, _, _), do: state

  defp interrupt_skill(%{skill: active} = state, reason) do
    Process.cancel_timer(active.timer)
    Process.exit(active.pid, :shutdown)
    # DOWN 后才发 stop；它不能撤销已提交的世界事务，只有权威 done 才确认停止。
    %{state | skill: %{active | cancelling: reason}}
  end

  defp finish_skill(%{skill: active} = state, result) do
    Process.cancel_timer(active.timer)
    Process.demonitor(active.ref, [:flush])
    if active.jev_pid, do: Process.exit(active.jev_pid, :shutdown)
    if active.jev_ref, do: Process.demonitor(active.jev_ref, [:flush])
    {status, reason, data} = case result do
      {:ok, data} -> {:done, nil, data}
      {:error, reason, metrics} -> {:rejected, reason, %{metrics: metrics}}
    end
    # 子进程未返回统计时保留未知；父脑自己发出的 Jev 次数始终确知。
    metrics = Map.update(Map.get(data, :metrics, %{}), :jev_request_count, active.jev_requests, fn
      nil -> nil
      count -> count + active.jev_requests
    end) |> Map.put(:parent_jev_request_count, active.jev_requests)
    data = Map.put(data, :metrics, metrics)
    # 荒野状态机已有事实 journal；其他技能在这里记一条结束经历。
    data = if active.command.skill == :wilderness do
      data
    else
      actor = state.observation.self
      experience = "Skill #{active.command.skill}: status=#{status}; reason=#{inspect(reason)}; " <>
        "request=#{inspect(active.command.args,limit: 20,printable_limit: 350)}; " <>
        "last_check=#{inspect(Map.get(metrics,:last_check),limit: 30,printable_limit: 500)}; " <>
        "result=#{inspect(Map.take(data,[:definition_id,:seq,:instance_id]),limit: 10)}"
      case Memory.journal(state.memory, actor.entity_id, String.slice(experience,0,1500), actor.position) do
        {:ok, _} -> data
        {:error, error} -> Map.put(data, :memory_error, error)
      end
    end
    Logger.info("npc_skill_outcome skill=#{active.command.skill} status=#{status} metrics=#{inspect(metrics)}")
    record_outcome(%{state | skill: nil, heard: false}, %{id: active.command.id, verb: active.command.skill,
      status: status, reason: reason, data: data})
  end

  defp exit_kind({%{__struct__: module}, _}), do: module
  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_), do: :worker_failed

  defp record_outcome(state, outcome) do
    state = remember_probe(state, outcome)
    position = state.observation && state.observation.self.position
    {call, calls} = Map.pop(state.calls, outcome.id)
    outcome = if call, do: Map.put(outcome, :command, call), else: outcome
    %{state | calls: calls, dirty: true, outcomes: Enum.take(remember(outcome, state.outcomes, position), @history)}
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

  @doc "Outcome 进历史（新在前）。look 将普通非空气格按列压缩，保留细化格的占用与归属；更早的 look 只留结论。"
  def remember(%{verb: :look, status: :done, data: %{probe_occupancy: cells}} = outcome, outcomes, _position) do
    columns =
      for(%{cell: [x, y, z], material: material} = cell <- cells, material != 0,
        # 有人花材料放下的格带上放置者的 entity_id（第三项）；天然地形与作者写入的格只有 [y, material]。
        do: {"#{x},#{z}", [y, material] ++ List.wrap(cell[:placed_by])}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    older = for o <- outcomes, do: if(o.verb == :look, do: %{o | data: nil}, else: o)
    data = Map.take(outcome.data, [:seq,:bounds_macro_inclusive,:outside,:attachments])
      |> Map.merge(%{solid: columns,refined: Enum.filter(cells,& &1.refined)})
    [%{outcome | data: data} | older]
  end

  # inspect 同理：只留模型用得上的身份与状态，更早的 inspect 只留结论。
  def remember(%{verb: :inspect, status: :done, data: %{property_states: rows}} = outcome, outcomes, position) do
    # micro 坐标 / 8 = 米；按到自己的距离取最近的 @nearest 件。
    nearest = fn rows ->
      rows |> Enum.sort_by(fn %{micro: {x, y, z}} -> distance({x / 8, y / 8, z / 8}, position) end) |> Enum.take(@nearest)
    end

    attachments =
      for %{owner: {id, type}} = row <- nearest.(Enum.filter(rows, &(&1.granularity == 3))) do
        %{attachment_id: id, kind: div(type, 3), axis: rem(type, 3), micro: row.micro}
        |> Map.merge(Map.take(row, [:material, :hp, :max_hp, :circuit]))
      end

    components =
      for %{owner: {birth, occurrence}} = row <- nearest.(Enum.filter(rows, &(&1.granularity == 2))),
        do: %{instance: [birth, occurrence], material: row.material, cells: row.observation_cells}

    data = Map.merge(Map.take(outcome.data,[:seq,:bounds_region_half_open]), %{
      attachments: attachments,
      components: components,
      total: %{attachments: Enum.count(rows, &(&1.granularity == 3)), components: Enum.count(rows, &(&1.granularity == 2))}
    })

    older = for o <- outcomes, do: if(o.verb == :inspect, do: %{o | data: nil}, else: o)
    [%{outcome | data: data} | older]
  end

  def remember(outcome, outcomes, _position), do: [outcome | outcomes]

  defp distance({x, y, z}, {px, py, pz}),
    do: :math.sqrt((x - px) * (x - px) + (y - py) * (y - py) + (z - pz) * (z - pz))

  # 有新情况、没有在途命令、没有在途请求、且过了最小间隔，才问一次。
  defp ask(%{dirty: true, asking: false, skill: nil, observation: %{pending: []} = observation} = state) do
    now = System.monotonic_time(:millisecond)

    if now - state.asked_ms >= @min_gap_ms do
      owner = self()
      query = state.profile.goal <> " " <> inspect(Enum.take(state.outcomes, 1), limit: 20, printable_limit: 300)
      experiences = Memory.context(state.memory, observation.self.entity_id, query)
      body = body(state.profile, observation, state.outcomes, experiences)
      pid = spawn_link(fn -> send(owner, {:answer, state.request.(state.profile.endpoint, body)}) end)
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
        Jason.encode!(%{
          goal: profile.goal,
          coordinates: Context.coordinates(),
          self: plain(observation.self),
          tools: profile.tools,
          # 背包：每种材料还能放几个整格；null = 还没读过。
          balances:
            observation.balances &&
              for(%{balance: balance} = b when balance > 0 <- observation.balances,
                do: %{material: b.material, cells: balance / b.cost}
              ),
          entities: Enum.map(observation.entities, &plain/1),
          outcomes: outcomes |> Enum.reverse() |> Enum.map(&plain/1)
        } |> Map.merge(memory_input(experiences))),
      tools: tools(profile),
      tool_choice: "required",
      parallel_tool_calls: false,
      reasoning: %{effort: Map.get(profile.endpoint, :effort, "low")},
      store: false
    }
  end

  defp memory_input(events) when is_list(events), do: %{experiences: plain(events)}
  defp memory_input(%{} = context), do: plain(context)

  # 元组 → 列表，其余原样；权威返回的 reason / data 可能含元组与原子。
  defp plain(%{} = map), do: Map.new(map, fn
    {:definition_id, <<_::256>> = id} -> {:definition_id, Base.encode16(id, case: :lower)}
    {k, v} -> {k, plain(v)}
  end)
  defp plain(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&plain/1)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(binary) when is_binary(binary), do: if(String.valid?(binary), do: binary, else: Base.encode16(binary))
  defp plain(other), do: other

  @doc false
  def request(endpoint, body) do
    ssl =
      [
        verify: :verify_peer,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++
        case endpoint do
          %{cacertfile: path} -> [cacertfile: String.to_charlist(path)]
          _ -> [cacerts: :public_key.cacerts_get()]
        end

    headers = [{~c"authorization", String.to_charlist("Bearer " <> endpoint.key)}]
    request = {String.to_charlist(endpoint.url), headers, ~c"application/json", Jason.encode!(body)}

    case :httpc.request(:post, request, [ssl: ssl, timeout: 60_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, response}} -> {:ok, Jason.decode!(response)}
      {:ok, {{_, status, _}, _, response}} -> {:error, {status, String.slice(response, 0, 300)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
