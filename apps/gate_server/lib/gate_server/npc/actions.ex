defmodule GateServer.Npc.Actions do
  @moduledoc """
  全局系统功能：Body 原子动作的能力条目（移动、工具、建造、液体、背包；施法见 `spells/1`）。条目形状与参数规格见
  `GateServer.Npc.Abilities`；命令形状见 `GateServer.Npc.Brain`，合法性仍由 Body 与权威裁决。

  目标句柄（`use_tool` / `dismantle` / `detach` 的 `target`）沿用 0x7D 的身份形状
  `%{granularity, micro, incarnation, owner, material, direction}`，原样取自 `probe_toward` 的结果或 inspect 行里的
  `target`（`Perception.project/3` 附上）；`direction` 为 nil 时 Body 从眼点瞄准（`WorldRequest.aim/2`）。
  经 Abilities 构造的句柄（LLM，以及 I3 起的行为树）只允许 granularity 0..3；人物 g5 只由直接产出规范命令的代码
  Brain 发出（D-13）；施法的目标只有 0x82 能表达的 g0..g2。附件的 kind / axis 在 `attach` 参数与 inspect 投影里是同一组名字
  （`attachment_names/1`）。
  """
  alias GateServer.Npc.Perception
  alias VoxelRegion.{Attachments, Spatial}

  # move_to 的到达容差（米）：LLM 与行为树经 Abilities 构造的移动命令都用它。
  @tolerance 0.5
  # 附件 kind / axis 的名字 → 码（Codec 0x81 的整数形）：attach 的参数枚举与 inspect 投影共用这一张表。
  @kinds %{"face" => 0, "edge" => 1}
  @axes %{"x" => 0, "y" => 1, "z" => 2}

  @doc "`move_to` 的到达容差（米）。"
  def tolerance, do: @tolerance

  @doc """
  附件身份（inspect 行或 g3 句柄，owner `{id, kind * 3 + axis}`）的 kind / axis 名字，与 `attach` 参数同一组字符串
  （kind `face` / `edge`，axis `x` / `y` / `z`）；槽地址取自 `VoxelRegion.Attachments.slot/1`。
  """
  def attachment_names(handle) do
    {kind, axis, _anchor} = Attachments.slot(handle)
    %{kind: name(@kinds, kind), axis: name(@axes, axis)}
  end

  defp name(table, code),
    do: Enum.find_value(table, fn {name, value} -> value == code && name end)

  @doc "原子动作条目（顺序固定）。"
  def entries do
    reach = Perception.reach()
    micro = Spatial.micro_resolution()
    cell = [x: :integer, y: :integer, z: :integer]
    vector = {:tuple, [:number, :number, :number]}

    [
      %{
        name: "move_to",
        group: :move,
        description:
          "走到水平坐标 (x, z)，自动寻路：会绕开障碍、按 self.body.move_to.max_step_macro 上台阶、从高处落下，但不会跳，也不进液体；" <>
            "单程水平不超过 #{reach} 米。同一处上下有几层能站时用 y 指定站立格（脚所在的那个空气格，整数），" <>
            "y 与脚所在格相差不超过 #{reach} 格，不指定写 null；不指定时只在脚下上下 #{GateServer.Npc.Body.path_margin()} 格内找路，" <>
            "目标比这更高或更低就给 y（直接用 survey 的 move_to_y，勿用 ground_y）。" <>
            "超出这些距离回 too_far；走不通会被拒绝：no_path = 现在没有路，" <>
            "stuck = 路上被堵住了，再调用一次会按现在的世界重新找路。",
        done:
          "走到 #{@tolerance} 米内、零输入帧已被权威处理且身体停稳（含落地；data.position、within_tolerance、settled）；到达或被拒后才会再次询问。",
        params: [x: :number, z: :number, y: {:nullable, :integer}],
        build: fn %{x: x, z: z, y: y}, _ ->
          %{verb: :move_to, position: {x, z}, tolerance: @tolerance, y: y}
        end
      },
      %{
        name: "stop",
        group: :move,
        description: "停下，顶替正在进行的移动。目标已完成或暂时无事可做时用 wait，不要反复调用 stop。",
        done: "零输入帧已被权威处理且身体停稳（data.position、settled）。",
        params: [],
        build: fn _, _ -> %{verb: :stop} end
      },
      %{
        name: "probe_toward",
        group: :act,
        description:
          "从眼睛沿 direction [dx, dy, dz] 探测这把工具射程内实际命中的方块、构件或附件（+X 是 [1,0,0]，+Z 是 [0,0,1]，Y 向上，" <>
            "自动归一化）；没有目标会被拒绝。射程与间隔见 read_catalog tools。",
        done: "data 是命中目标的身份，其中 data.target 原样交给 use_tool / dismantle 的 target。",
        params: [direction: vector, tool_id: :belt],
        build: fn %{direction: direction, tool_id: tool}, _ ->
          %{verb: :probe_toward, tool_id: tool, direction: unit(direction)}
        end
      },
      %{
        name: "use_tool",
        group: :act,
        description:
          "用工具作用于 target：挖掘、点火 / 灭火、加热 / 冷却、电路开关都是 use_tool 换一个 tool_id，效果由这把工具的 action 决定" <>
            "（见 read_catalog tools）。target 原样抄 probe_toward 结果或 inspect 行里的 target，不要自己编；" <>
            "target.direction 为 null 时从眼睛瞄准目标中心。挖下的材料进自己的 balances，一个目标通常要用多次。",
        done: "World 已提交（data.seq）；被拒时 reason 原样来自权威。",
        params: [tool_id: :belt, target: handle([0, 1, 2, 3])],
        build: &target_command(:use_tool, &1, &2)
      },
      %{
        name: "dismantle",
        group: :act,
        description:
          "拆解一件 prefab 构件，按剩余燃料把材料退回自己的 balances。target 原样抄 probe_toward 结果或 inspect 的 components 行里的 target；" <>
            "target.direction 为 null 时从眼睛瞄准。",
        done: "World 已提交（data.seq），材料已退回。",
        params: [tool_id: :belt, target: handle([0, 1, 2, 3])],
        build: &target_command(:dismantle, &1, &2)
      },
      %{
        name: "place",
        group: :build,
        description:
          "花自己 balances 里的 material，在空气格 (x, y, z) 放一个实心格（1 格 = 1 米，整数格坐标）。" <>
            "格心要在这把工具的射程内（见 read_catalog tools）。",
        done: "World 已提交（data.seq），balances 随之刷新。",
        params: cell ++ [material: :integer, tool_id: :belt],
        build: &production(:place, &1, &2)
      },
      %{
        name: "scoop",
        group: :liquid,
        description: "用液体盛取工具从格 (x, y, z) 盛起 material 液体，进自己的 balances。工具须是液体盛取工具。",
        done: "World 已提交（data.seq），balances 随之刷新。",
        params: cell ++ [material: :integer, tool_id: :belt],
        build: &production(:scoop, &1, &2)
      },
      %{
        name: "pour",
        group: :liquid,
        description: "用液体倾倒工具把自己 balances 里的 material 液体倒进格 (x, y, z)。工具须是液体倾倒工具。",
        done: "World 已提交（data.seq），balances 随之刷新。",
        params: cell ++ [material: :integer, tool_id: :belt],
        build: &production(:pour, &1, &2)
      },
      %{
        name: "craft",
        group: :inventory,
        description:
          "按目录配方合成 material 一次：扣配方输入、得到产物单位，都在自己的 balances 里。" <>
            "哪些材料能合成、配方是什么见 read_catalog materials 的 recipe。",
        done: "World 已提交（data.seq），balances 随之刷新。",
        params: [material: :integer],
        build: fn %{material: material}, _ -> %{verb: :craft, material: material} end
      },
      %{
        name: "eat",
        group: :inventory,
        description:
          "吃一株自己 balances 里的可食材料 material（一株 = 目录 place_units 单位）。哪些能吃、营养多少见 read_catalog materials 的 edible。",
        done: "World 已提交（data.seq）；营养由身体随后吸收，见 self.body_state。",
        params: [material: :integer],
        build: fn %{material: material}, _ -> %{verb: :eat, material: material} end
      },
      %{
        name: "attach",
        group: :build,
        description:
          "花 material 在实心格表面贴一件附件。kind = face（面片，axis 是法线轴）或 edge（棱条，axis 是走向）；" <>
            "size 1 或 8；(x, y, z) 是 micro 坐标（1 格 = #{micro} micro），size 8 时须是 8 的倍数。",
        done: "World 已提交（data.seq）；这件附件的身份用 inspect 查。",
        params:
          [kind: {:enum, @kinds}, axis: {:enum, @axes}, size: {:enum, [1, 8]}] ++
            cell ++ [material: :integer, tool_id: :belt],
        build: fn args, _ ->
          %{
            verb: :attach,
            kind: args.kind,
            axis: args.axis,
            size: args.size,
            anchor: {args.x, args.y, args.z},
            material: args.material,
            tool_id: args.tool_id
          }
        end
      },
      %{
        name: "detach",
        group: :build,
        description: "拆下一件附件，材料退回自己的 balances。target 原样抄 inspect 的 attachments 行里的 target。",
        done: "World 已提交（data.seq），材料已退回。",
        params: [tool_id: :belt, target: handle([3])],
        # 附件槽地址由句柄恢复（VoxelRegion.Attachments.slot/1）；拆除按槽寻址，size 不参与。
        build: fn %{tool_id: tool, target: target}, _ ->
          {kind, axis, anchor} = Attachments.slot(target)

          %{
            verb: :detach,
            kind: kind,
            axis: axis,
            size: 1,
            anchor: anchor,
            material: target.material,
            attachment_id: target.incarnation,
            tool_id: tool
          }
        end
      },
      %{
        name: "prefab",
        group: :build,
        description:
          "预制件。op = place：以 micro 坐标 (x, y, z)（1 格 = #{micro} micro）为锚点、orientation 0–23 放置 definition；" <>
            "remove：拆掉 instance；replace：把 instance 换成 definition。definition 是 64 位十六进制 id（材料单见 read_catalog prefab），" <>
            "instance 是 inspect 的 components 行里的 [birth, occurrence]；本次 op 用不到的参数写 null。" <>
            "涉及的格须在部署的编辑盒内，否则 out_of_bounds。",
        done: "World 已提交（data.seq）。",
        params: [
          op: {:enum, %{"place" => :place, "remove" => :remove, "replace" => :replace}},
          definition: {:nullable, :hex32},
          x: {:nullable, :integer},
          y: {:nullable, :integer},
          z: {:nullable, :integer},
          orientation: {:nullable, :integer},
          instance: {:nullable, {:tuple, [:integer, :integer]}}
        ],
        build: &prefab/2
      }
    ]
  end

  @doc """
  施法条目（组 `:magic`：`cast_spell`、`cancel_cast`），授予条件 = `profile.spells` 非空。`profile.spells` 是作者给的
  法术带 `%{名字 => 程序字节}`（0x82 的程序字段，UTF-8 JSON；D-10：LLM 只选名字）：schema 只列名字，译码时由名字取出
  程序字节。目标句柄只取 0x82 能表达的 granularity 0..2（附件 g3 与人物 g5 都不行）。
  """
  def spells(profile) do
    case Map.get(profile, :spells, %{}) do
      spells when map_size(spells) == 0 ->
        []

      spells ->
        [
          %{
            name: "cast_spell",
            group: :magic,
            description:
              "对 target 施放作者配置的法术 spell（只选名字，程序已定）。target 原样抄 probe_toward 结果或 inspect 行里的 target，" <>
                "target.direction 为 null 时从眼睛瞄准目标中心。施放先有前摇，前摇期间工具、建造等世界动作回 casting，" <>
                "可用 cancel_cast 取消；能量或相干度不足会走火（扣掉的能量落在脚下，同样是已提交事务）。",
            done:
              "前摇结束且 World 已结算（data.seq）：data.outcome 为 null 是正常施放，misfire_energy / misfire_coherence 是走火；" <>
                "data.caster 是结算后的施法者状态（能量、容量、相干度、本次支出），同 self.caster。",
            params: [spell: {:enum, spells}, target: handle([0, 1, 2])],
            build: fn %{spell: program, target: target}, _ ->
              Map.merge(aimed(target), %{verb: :cast_spell, program: program})
            end
          },
          %{
            name: "cancel_cast",
            group: :magic,
            description: "取消自己正在前摇的施法，不扣能量。没有在前摇的施法时回 no_active_cast。",
            done: "角色 owner 已撤销前摇（data 为空）；原 cast_spell 随后以 cast_cancelled 被拒。",
            params: [],
            build: fn _, _ -> %{verb: :cancel_cast} end
          }
        ]
    end
  end

  # 句柄规格：granularity 只取给定集合（LLM 投影不含 g5）；direction 可空。
  defp handle(granularities),
    do:
      {:map,
       [
         granularity: {:enum, granularities},
         micro: {:tuple, [:integer, :integer, :integer]},
         incarnation: :integer,
         owner: {:tuple, [:integer, :integer]},
         material: :integer,
         direction: {:nullable, {:tuple, [:number, :number, :number]}}
       ]}

  defp target_command(verb, %{tool_id: tool, target: target}, _),
    do: Map.merge(aimed(target), %{verb: verb, tool_id: tool})

  # 句柄拆成命令的 direction（可空；给了就归一化）与 target（身份字段）：use_tool / dismantle / cast_spell 共用。
  defp aimed(target),
    do: %{
      direction: target.direction && unit(target.direction),
      target: Map.delete(target, :direction)
    }

  defp production(verb, args, _),
    do: %{
      verb: verb,
      coord: {args.x, args.y, args.z},
      material: args.material,
      tool_id: args.tool_id
    }

  defp prefab(%{op: :place} = args, _),
    do: %{
      verb: :prefab_place,
      definition_id: args.definition,
      anchor: {args.x, args.y, args.z},
      orientation: args.orientation
    }

  defp prefab(%{op: :remove} = args, _), do: %{verb: :prefab_remove, instance_id: args.instance}

  defp prefab(%{op: :replace} = args, _),
    do: %{verb: :prefab_replace, instance_id: args.instance, definition_id: args.definition}

  # 零向量原样留给 Body 判为不合法。
  defp unit({dx, dy, dz}) do
    length = :math.sqrt(dx * dx + dy * dy + dz * dz)
    if length > 0, do: {dx / length, dy / length, dz / length}, else: {dx, dy, dz}
  end
end
