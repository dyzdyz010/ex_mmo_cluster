defmodule GateServer.Npc.Brain.Llm do
  @moduledoc """
  全局系统功能：LLM 决策后端（OpenAI Responses 线格式）。回调只把事件转给自己的进程，立刻返回；
  该进程在“没有在途命令且有新情况”时问一次模型，把模型的工具调用译成命令，用 `Body.command/2` 投回。
  每次请求无状态：目标 + 当前 Observation + 最近的 Outcome。模型的输出是外部输入，合法性由 Body 与权威裁决。

  profile:
      %{goal: "自然语言目标", tool_id: 工具,
        endpoint: %{url:, key:, model:, cacertfile: 可选}}
  """
  @behaviour GateServer.Npc.Brain
  require Logger

  @history 8
  # 两次请求的最小间隔（毫秒）：连续被拒时不空转打接口。
  @min_gap_ms 1_000

  @tools [
    %{
      type: "function",
      name: "move_to",
      description: "沿直线走到水平坐标 (x, z)，无寻路；到达后才会再次询问。",
      parameters: %{
        type: "object",
        properties: %{x: %{type: "number"}, z: %{type: "number"}},
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
        properties: %{dx: %{type: "number"}, dy: %{type: "number"}, dz: %{type: "number"}},
        required: ["dx", "dy", "dz"],
        additionalProperties: false
      }
    },
    %{
      type: "function",
      name: "use_tool",
      description: "用工具攻击最近一次 probe_toward 命中的目标。攻击有约 0.5 秒的间隔限制；一个目标通常要多次攻击。",
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
  ]

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

  @doc "把一次 Responses 应答里的工具调用译成命令；`probe` 是最近一次成功探测 `%{direction:, target:}`。"
  def commands(%{"output" => output}, tool_id, probe, next_id) do
    output
    |> Enum.filter(&(&1["type"] == "function_call"))
    |> Enum.with_index(next_id)
    |> Enum.map(fn {call, id} ->
      args = Jason.decode!(call["arguments"])

      case call["name"] do
        "move_to" ->
          %{id: id, verb: :move_to, position: {args["x"], args["z"]}, tolerance: 0.5}

        "stop" ->
          %{id: id, verb: :stop}

        "probe_toward" ->
          %{id: id, verb: :probe_toward, tool_id: tool_id, direction: unit(args)}

        # 只属于本 adapter：不发给 Body，挂起询问。
        "wait" ->
          %{id: id, verb: :wait, seconds: args["seconds"]}

        "use_tool" ->
          %{
            id: id,
            verb: :use_tool,
            tool_id: tool_id,
            direction: probe && probe.direction,
            target: probe && probe.target
          }
      end
    end)
  end

  defp unit(%{"dx" => dx, "dy" => dy, "dz" => dz}) when is_number(dx) and is_number(dy) and is_number(dz) do
    length = :math.sqrt(dx * dx + dy * dy + dz * dz)
    if length > 0, do: {dx / length, dy / length, dz / length}, else: {dx, dy, dz}
  end

  defp unit(_), do: nil

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
          %{state | dirty: true, outcomes: Enum.take([outcome | state.outcomes], @history)}

        {:answer, {:ok, response}} ->
          {waits, commands} =
            response
            |> commands(state.profile.tool_id, state.probe, state.next_id)
            |> Enum.split_with(&(&1.verb == :wait))

          for command <- commands, do: GateServer.Npc.Body.command(state.body, command)

          # 每次询问都要花钱：模型说等多久就挂起多久（夹在 1–300 秒），到点再标记有新情况。
          for %{seconds: seconds} <- waits, is_number(seconds),
            do: Process.send_after(self(), :wake, round(min(300, max(1, seconds)) * 1_000))

          probes =
            for %{verb: :probe_toward, id: id, direction: direction} <- commands,
                into: state.probes,
                do: {id, direction}

          %{state | asking: false, probes: probes, next_id: state.next_id + length(commands)}

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

  defp remember_probe(state, _), do: state

  # 有新情况、没有在途命令、没有在途请求、且过了最小间隔，才问一次。
  defp ask(%{dirty: true, asking: false, observation: %{pending: []} = observation} = state) do
    now = System.monotonic_time(:millisecond)

    if now - state.asked_ms >= @min_gap_ms do
      owner = self()
      body = body(state.profile, observation, state.outcomes)
      spawn_link(fn -> send(owner, {:answer, state.request.(state.profile.endpoint, body)}) end)
      %{state | dirty: false, asking: true, asked_ms: now}
    else
      state
    end
  end

  defp ask(state), do: state

  @doc "一次请求体：目标、当前 Observation、最近 Outcome（旧在前），要求恰好一次工具调用。"
  def body(profile, observation, outcomes) do
    %{
      model: profile.endpoint.model,
      instructions:
        "你控制体素世界里的一个 NPC。每次只调用一个工具来推进目标；不要输出文字。" <>
          "坐标单位米，Y 向上，水平面是 X/Z。上一步的结果在 outcomes 里：status=rejected 表示权威拒绝，reason 是原因。",
      input:
        Jason.encode!(%{
          goal: profile.goal,
          self: plain(observation.self),
          entities: Enum.map(observation.entities, &plain/1),
          outcomes: outcomes |> Enum.reverse() |> Enum.map(&plain/1)
        }),
      tools: @tools,
      tool_choice: "required",
      parallel_tool_calls: false,
      reasoning: %{effort: "low"},
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
