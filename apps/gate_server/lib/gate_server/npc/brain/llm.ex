defmodule GateServer.Npc.Brain.Llm do
  @moduledoc """
  全局系统功能：LLM 决策后端（OpenAI Responses 线格式）。回调只把事件转给自己的进程，立刻返回；
  该进程在“没有在途命令且有新情况”时问一次模型，把模型的工具调用译成命令，用 `Body.command/2` 投回。
  每次请求无状态：目标 + 当前 Observation + 最近的 Outcome + 模型自己的便签。模型的输出是外部输入，合法性由 Body 与权威裁决。
  请求之间模型看不到自己上一次调用了什么，所以给它看的每条 Outcome 都附上当初那次调用（`command`）：
  只有 `{id, verb, status}` 时模型对不上“哪一格放好了”，实测会原地反复 look。
  便签（`note` 工具）是长目标的记忆：Outcome 只留最近 8 条，计划与进度要靠模型自己写下来；它只属于本 adapter，不进世界。

  profile:
      %{goal: "自然语言目标", tools: %{tool_id => "用途"},   # 这个 NPC 带着的工具；模型只能从中选
        endpoint: %{url:, key:, model:, effort: 可选（思考强度，接口认的 "low" / "medium" / "high" 等，缺省 "low"）, cacertfile: 可选}}
  """
  @behaviour GateServer.Npc.Brain
  require Logger

  @history 8
  # inspect 在建成区能有几百行：只把离自己最近的这么多件给模型，总数另报。
  @nearest 24
  # 两次请求的最小间隔（毫秒）：连续被拒时不空转打接口。
  @min_gap_ms 1_000

  @cell %{x: %{type: "integer"}, y: %{type: "integer"}, z: %{type: "integer"}}

  # 工具表随 profile 的工具带生成：tool_id 必填且只能取带着的 id，模型无从编造。
  defp tools(%{tools: belt}) do
    tool_id = %{type: "integer", enum: Map.keys(belt), description: "用哪个工具，见输入里的 tools。"}

    [
      %{
        type: "function",
        name: "move_to",
        description:
          "走到水平坐标 (x, z)，自动寻路：会绕开障碍、走上一格高的台阶、从高处落下，但不会跳，也不进液体；单程水平不超过 32 米。" <>
            "同一处上下有几层能站时用 y 指定站立格（脚所在的那个空气格，整数）。走不通会被拒绝：no_path = 现在没有路（高差超过一格就得先砌台阶），" <>
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
        name: "look",
        description:
          "看一个整数格闭区间 (x0,y0,z0)–(x1,y1,z1) 里有什么：1 格 = 1 米，格 (x,y,z) 占据 [x,x+1)×[y,y+1)×[z,z+1)。" <>
            "最多 512 格，各边离自己不超过 32 米。结果只列非空气格（按 \"x,z\" 列给出 [y, material]），没列出的都是空气。",
        parameters: %{
          type: "object",
          properties: %{
            x0: %{type: "integer"},
            y0: %{type: "integer"},
            z0: %{type: "integer"},
            x1: %{type: "integer"},
            y1: %{type: "integer"},
            z1: %{type: "integer"}
          },
          required: ["x0", "y0", "z0", "x1", "y1", "z1"],
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
          "预制件（需要建造者权限）。op = place：以 micro 坐标 (x,y,z)（1 格 = 8 micro）为锚点、orientation 0–23 放置 definition；" <>
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
        name: "inspect",
        description:
          "列出周围（自己所在 64 米 tile 及相邻 tile）的附件与预制件构件：附件给 attachment_id、kind、axis、micro 坐标、material、hp、电路状态；" <>
            "构件给 instance [birth, occurrence] 与占的格。只列离自己最近的 24 件，total 是总数。detach、prefab remove / replace、对附件 use_tool 都要用这里的身份。",
        parameters: %{type: "object", properties: %{}, additionalProperties: false}
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
        name: "note",
        description:
          "改写你的便签（输入里的 notes，最多 1500 字，整段替换）。outcomes 只保留最近几条，更早的事你会忘：" <>
            "长任务把计划、已完成的部分、踩过的坑写在这里。写完会立刻再次询问你。",
        parameters: %{
          type: "object",
          properties: %{text: %{type: "string"}},
          required: ["text"],
          additionalProperties: false
        }
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
    ]
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
        "note" ->
          %{id: id, verb: :note, text: args["text"]}

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
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    %{
      body: body,
      profile: profile,
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
      notes: nil,
      dirty: true,
      asking: false,
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
          state = remember_probe(state, outcome)
          position = state.observation && state.observation.self.position
          {call, calls} = Map.pop(state.calls, outcome.id)
          outcome = if call, do: Map.put(outcome, :command, call), else: outcome
          state = %{state | calls: calls}
          %{state | dirty: true, outcomes: Enum.take(remember(outcome, state.outcomes, position), @history)}

        {:answer, {:ok, response}} ->
          {local, commands} =
            response
            |> commands(state.probe, state.things, state.next_id)
            |> Enum.split_with(&(&1.verb in [:wait, :note]))

          {notes, waits} = Enum.split_with(local, &(&1.verb == :note))

          Logger.info("npc_llm_decision #{inspect(local ++ commands, limit: :infinity)}")
          for command <- commands, do: GateServer.Npc.Body.command(state.body, command)

          # 每次询问都要花钱：模型说等多久就挂起多久（夹在 1–300 秒），到点再标记有新情况。
          for %{seconds: seconds} <- waits, is_number(seconds),
            do: Process.send_after(self(), :wake, round(min(300, max(1, seconds)) * 1_000))

          probes =
            for %{verb: :probe_toward, id: id, direction: direction} <- commands,
                into: state.probes,
                do: {id, direction}

          # 便签没有 Outcome：写完直接标记有新情况，下一轮带着新便签再问。
          state =
            case notes do
              [%{text: text} | _] when is_binary(text) -> %{state | notes: String.slice(text, 0, 1500), dirty: true}
              _ -> state
            end

          sent = Map.take(calls(response, state.next_id), Enum.map(commands, & &1.id))
          %{state | asking: false, probes: probes, calls: Map.merge(state.calls, sent), next_id: state.next_id + length(commands)}

        :wake ->
          %{state | dirty: true}

        {:answer, {:error, reason}} ->
          Logger.warning("npc_llm_request_failed reason=#{inspect(reason)}")
          %{state | asking: false, dirty: true}
      end

    loop(ask(state))
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

  @doc "Outcome 进历史（新在前）。`look` 的原样快照太大：只留非空气格，按 \"x,z\" 列聚成 [y, material]；更早的 look 只留结论。"
  def remember(%{verb: :look, status: :done, data: %{probe_occupancy: cells}} = outcome, outcomes, _position) do
    columns =
      for(%{cell: [x, y, z], material: material} <- cells, material != 0, do: {"#{x},#{z}", [y, material]})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    older = for o <- outcomes, do: if(o.verb == :look, do: %{o | data: nil}, else: o)
    [%{outcome | data: %{solid: columns}} | older]
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

    data = %{
      attachments: attachments,
      components: components,
      total: %{attachments: Enum.count(rows, &(&1.granularity == 3)), components: Enum.count(rows, &(&1.granularity == 2))}
    }

    older = for o <- outcomes, do: if(o.verb == :inspect, do: %{o | data: nil}, else: o)
    [%{outcome | data: data} | older]
  end

  def remember(outcome, outcomes, _position), do: [outcome | outcomes]

  defp distance({x, y, z}, {px, py, pz}),
    do: :math.sqrt((x - px) * (x - px) + (y - py) * (y - py) + (z - pz) * (z - pz))

  # 有新情况、没有在途命令、没有在途请求、且过了最小间隔，才问一次。
  defp ask(%{dirty: true, asking: false, observation: %{pending: []} = observation} = state) do
    now = System.monotonic_time(:millisecond)

    if now - state.asked_ms >= @min_gap_ms do
      owner = self()
      body = body(state.profile, observation, state.outcomes, state.notes)
      spawn_link(fn -> send(owner, {:answer, state.request.(state.profile.endpoint, body)}) end)
      %{state | dirty: false, asking: true, asked_ms: now}
    else
      state
    end
  end

  defp ask(state), do: state

  @doc "一次请求体：目标、当前 Observation、最近 Outcome（旧在前），要求恰好一次工具调用。"
  def body(profile, observation, outcomes, notes \\ nil) do
    %{
      model: profile.endpoint.model,
      instructions:
        "你控制体素世界里的一个 NPC。每次只调用一个工具来推进目标；不要输出文字。" <>
          "坐标单位米，Y 向上，水平面是 X/Z。上一步的结果在 outcomes 里：status=rejected 表示权威拒绝，reason 是原因。" <>
          "眼睛在 self.position 上方 0.6 米，探测与射程都从眼睛算；balances 是你的背包（每种 material 还能放几个整格）。" <>
          "notes 是你自己上次写的便签；outcomes 只有最近几条。",
      input:
        Jason.encode!(%{
          goal: profile.goal,
          notes: notes,
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
        }),
      tools: tools(profile),
      tool_choice: "required",
      parallel_tool_calls: false,
      reasoning: %{effort: Map.get(profile.endpoint, :effort, "low")},
      store: false
    }
  end

  # 元组 → 列表，其余原样；权威返回的 reason / data 可能含元组与原子。
  defp plain(%{} = map), do: Map.new(map, fn {k, v} -> {k, plain(v)} end)
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
