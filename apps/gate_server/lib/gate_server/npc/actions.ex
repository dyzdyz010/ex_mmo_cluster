defmodule GateServer.Npc.Actions do
  @moduledoc """
  全局系统功能：Body 原子动作的公共能力目录。工具参数 schema 与“工具调用 → Body 命令”的译码只在这里定义一次，
  LLM 适配器直接投影为工具，脚本／行为树可读取同一份参数契约；命令合法性仍由 Body 与权威裁决。
  感知（`Perception`）、记忆（`Memory`）、长技能（`Skills`）各自拥有自己的目录。
  """

  @cell %{x: %{type: "integer"}, y: %{type: "integer"}, z: %{type: "integer"}}

  @doc "原子动作的工具表；tool_id 必填且只能取 profile 工具带里的 id，模型无从编造。"
  def tools(%{tools: belt}) do
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
      }
    ]
  end

  @doc """
  一次工具调用译成 Body 命令；不是原子动作返回 nil。`probe` 是最近一次成功探测 `%{direction:, target:}`，
  `things` 是最近一次 inspect 的附件身份（attachment_id => 目标）。参数取值的合法性留给 Body 判定。
  """
  def command(name, args, id, probe, things)

  def command("move_to", args, id, _, _) do
    move = %{id: id, verb: :move_to, position: {args["x"], args["z"]}, tolerance: 0.5}
    if args["y"], do: Map.put(move, :y, args["y"]), else: move
  end

  def command("stop", _, id, _, _), do: %{id: id, verb: :stop}

  def command("probe_toward", args, id, _, _),
    do: %{id: id, verb: :probe_toward, tool_id: args["tool_id"], direction: unit(args)}

  def command(name, args, id, _, _) when name in ["place", "scoop", "pour"],
    do: %{
      id: id,
      verb: %{"place" => :place, "scoop" => :scoop, "pour" => :pour}[name],
      coord: {args["x"], args["y"], args["z"]},
      material: args["material"],
      tool_id: args["tool_id"]
    }

  def command("query_balances", _, id, _, _), do: %{id: id, verb: :query_balances}
  def command("say", args, id, _, _), do: %{id: id, verb: :say, text: args["text"]}

  # 附件按身份寻址、不经射线；direction 只需是单位向量。不在最近一次 inspect 里的 id 不构成目标。
  def command("use_tool", %{"attachment_id" => attachment} = args, id, _, things),
    do: %{
      id: id,
      verb: :use_tool,
      tool_id: args["tool_id"],
      direction: {1.0, 0.0, 0.0},
      target: Map.get(things, attachment, :unknown_attachment)
    }

  def command("use_tool", args, id, probe, _),
    do: %{
      id: id,
      verb: :use_tool,
      tool_id: args["tool_id"],
      direction: probe && probe.direction,
      target: probe && probe.target
    }

  def command(name, args, id, _, _) when name in ["attach", "detach"],
    do: %{
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

  def command("prefab", args, id, _, _),
    do: %{
      id: id,
      verb:
        %{"place" => :prefab_place, "remove" => :prefab_remove, "replace" => :prefab_replace}[
          args["op"]
        ],
      definition_id: hex(args["definition"]),
      anchor: {args["x"], args["y"], args["z"]},
      orientation: args["orientation"],
      instance_id: instance(args["instance"])
    }

  def command(_, _, _, _, _), do: nil

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

  # [birth, occurrence] → 元组；其余形状原样留给 Body 判为不合法。
  defp instance(list) when is_list(list), do: List.to_tuple(list)
  defp instance(other), do: other
end
