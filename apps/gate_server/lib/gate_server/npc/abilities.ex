defmodule GateServer.Npc.Abilities do
  @moduledoc """
  全局系统功能：NPC 决策侧唯一的能力定义（角色能力函数库，设计稿
  docs/10-active/cross-cutting/2026-10-07-character-capability-library.md §5）。

  组合各域条目：`Actions`（移动、工具、建造、液体、背包）、`Perception`（look / inspect / query_balances /
  read_catalog）、`Attention`（关注与目标组）、`Memory`（长期记忆）、`Skills`（已配置的长技能）。每个条目只有
  `%{name, group, done, description, params, build}`：

  - `name`：稳定 snake_case 英文，即 LLM 工具名、行为树 act 名、技能名；
  - `group`：`:move | :sense | :attend | :act | :build | :liquid | :inventory | :memory | :skill`，供 `profile.groups` 裁剪；
  - `done`：done 的确切含义（一句话），`description`：给模型看的说明，数字由各域的源常量插值；
  - `params`：一份手写参数规格，同时生成 strict JSON Schema（`tools/1`）与参数译码（`command/4`）；
    技能是 `{:skill, schema}`，schema 原样取自技能的 `definition/1`，参数透传给技能；
  - `build`：`(定型参数, profile) -> 不含 :id 的规范命令`，命令形状只在 `GateServer.Npc.Brain` 的 moduledoc。

  参数规格（spec）：

      :integer | :number | :string
      :hex32                                   # 64 位十六进制字符串 → 32 字节
      {:enum, %{"字符串" => 值}}               # 字符串枚举 → 码 / 原子
      {:enum, [整数]}                          # 整数枚举
      :belt                                    # 整数枚举 = profile.tools 的键（工具带）
      {:tuple, [spec]}                         # 定长数组 → 元组（元素同型，schema 取首元素）
      {:map, [{atom, spec}]}                   # 对象 → 原子键 map
      {:nullable, spec}                        # 可为 null

  译码只认 JSON 写法（字符串键、数组），当前调用方都给这种形状；对象里多余的键忽略，可空字段缺键视为 null。
  译码是这里唯一的形状校验（不另写通用 JSON Schema 校验器），取值合法性仍只由 Body 与权威裁决。
  `:belt` 只约束投影（工具带外的 id 不出现在 schema 里），译码只要求整数，World 受理目录里任何 tool_id。

  授予条件也只约束投影：`profile.groups`（缺省全部）、带 `:belt` 的条目要求 `profile.tools` 非空、技能条目要求
  配置在 `profile.skills`。schema 只依赖 profile，不随余额等观察状态增删（保护提示缓存）。

  不进条目：`say`（聊天占位，Body 的 stub 保留、不投影）、`cancel_skill`（Runtime 命令）、`wait`（LLM 适配器本地）、
  人物目标 g5 句柄（D-13）。调用方是 JSON 形参数的适配层：`Brain.Llm`、`design_house` 的共享工具；I3 的行为树 `act`
  叶子也将经这里，与 LLM 共用同一组规格（句柄 granularity 0..3）。g5 只由直接产出规范命令的代码 Brain（如 Routine）
  发出；Patrol / Routine 不经这里，Intent 与 World 不读它。
  """
  alias GateServer.Npc.{Actions, Attention, Memory, Perception, Skills}

  # D-2：2026-10-08 对当前代理做过一次 strict 工具 live 请求（enum、nullable、定长数组、嵌套对象），代理接受并按 schema 调用。
  @strict true

  @type group ::
          :move | :sense | :attend | :act | :build | :liquid | :inventory | :memory | :skill
  @type spec ::
          :integer
          | :number
          | :string
          | :hex32
          | :belt
          | {:enum, %{String.t() => term()} | [integer()]}
          | {:tuple, [spec()]}
          | {:map, [{atom(), spec()}]}
          | {:nullable, spec()}
  @type entry :: %{
          name: String.t(),
          group: group(),
          done: String.t(),
          description: String.t(),
          params: [{atom(), spec()}] | {:skill, map()},
          build: (map(), map() -> map())
        }

  @doc "通过 groups 与授予条件的条目，顺序固定（Actions、Perception、Attention、Memory、Skills）。"
  @spec entries(map()) :: [entry()]
  def entries(profile) do
    groups = Map.get(profile, :groups)
    belt = Map.get(profile, :tools, %{})

    for entry <-
          Actions.entries() ++
            Perception.entries() ++
            Attention.entries() ++ Memory.entries() ++ Skills.entries(profile),
        groups == nil or entry.group in groups,
        map_size(belt) > 0 or not belt?(entry.params),
        do: entry
  end

  @doc "LLM 投影：每个条目一个 strict 函数工具，说明后接 done 的含义。"
  @spec tools(map()) :: [map()]
  def tools(profile) do
    for entry <- entries(profile) do
      %{
        type: "function",
        name: entry.name,
        description: entry.description <> " 完成：" <> entry.done,
        parameters: schema(entry.params, profile),
        strict: @strict
      }
    end
  end

  @doc """
  一次调用 → 规范命令（带 `:id`）。命中且译码成功 → `build` 的输出加 `:id`；args 不是 map 或形状不对 →
  `%{id:, verb: :invalid_tool_arguments, tool: name}`；没有这个条目（含被 groups 裁掉的）→
  `%{id:, verb: :unknown_tool, tool: name}`。后两种由适配层本地回报，不发给 Body。
  """
  @spec command(String.t(), term(), term(), map()) :: map()
  def command(name, args, id, profile) do
    case Enum.find(entries(profile), &(&1.name == name)) do
      nil ->
        %{id: id, verb: :unknown_tool, tool: name}

      entry ->
        case decode(entry.params, args) do
          {:ok, typed} -> Map.put(entry.build.(typed, profile), :id, id)
          :error -> %{id: id, verb: :invalid_tool_arguments, tool: name}
        end
    end
  end

  # —— 一份规格 → strict JSON Schema ——
  # 每个 object：additionalProperties false、全部属性进 required；可空写 type: [t, "null"]（枚举另加 null）。

  defp schema({:skill, parameters}, _profile), do: parameters
  defp schema(fields, profile), do: object(fields, profile)

  defp object(fields, profile),
    do: %{
      type: "object",
      properties: Map.new(fields, fn {key, spec} -> {key, json_schema(spec, profile)} end),
      required: Enum.map(fields, fn {key, _} -> Atom.to_string(key) end),
      additionalProperties: false
    }

  defp json_schema(:integer, _), do: %{type: "integer"}
  defp json_schema(:number, _), do: %{type: "number"}
  defp json_schema(:string, _), do: %{type: "string"}
  defp json_schema(:hex32, _), do: %{type: "string"}

  defp json_schema(:belt, profile),
    do: %{type: "integer", enum: profile |> Map.get(:tools, %{}) |> Map.keys() |> Enum.sort()}

  defp json_schema({:enum, %{} = values}, _),
    do: %{type: "string", enum: values |> Map.keys() |> Enum.sort()}

  defp json_schema({:enum, values}, _), do: %{type: "integer", enum: values}

  defp json_schema({:tuple, [first | _] = specs}, profile),
    do: %{
      type: "array",
      items: json_schema(first, profile),
      minItems: length(specs),
      maxItems: length(specs)
    }

  defp json_schema({:map, fields}, profile), do: object(fields, profile)

  defp json_schema({:nullable, spec}, profile) do
    inner = json_schema(spec, profile)
    nullable = %{inner | type: [inner.type, "null"]}
    if Map.has_key?(inner, :enum), do: %{nullable | enum: inner.enum ++ [nil]}, else: nullable
  end

  # 工具带只出现在顶层参数（tool_id）。
  defp belt?({:skill, _}), do: false

  defp belt?(fields) when is_list(fields),
    do: Enum.any?(fields, fn {_, spec} -> spec == :belt end)

  # —— 同一份规格 → 定型参数 ——

  # 技能参数原样透传给技能（JSON 形：字符串键、列表；技能的 run/3 只认这一种写法）。
  defp decode({:skill, _}, args) when is_map(args), do: {:ok, args}
  defp decode(fields, args) when is_list(fields) and is_map(args), do: fields(fields, args)
  defp decode(_, _), do: :error

  defp fields(fields, args) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, spec}, {:ok, typed} ->
      case value(spec, Map.get(args, Atom.to_string(key))) do
        {:ok, value} -> {:cont, {:ok, Map.put(typed, key, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  # 缺键等于 null，只有可空字段接受。
  defp value({:nullable, _}, nil), do: {:ok, nil}
  defp value({:nullable, spec}, value), do: value(spec, value)
  defp value(:integer, value) when is_integer(value), do: {:ok, value}
  defp value(:number, value) when is_number(value), do: {:ok, value}
  defp value(:string, value) when is_binary(value), do: {:ok, value}
  defp value(:belt, value) when is_integer(value), do: {:ok, value}

  defp value(:hex32, text) when is_binary(text) do
    case Base.decode16(text, case: :mixed) do
      {:ok, <<_::256>> = id} -> {:ok, id}
      _ -> :error
    end
  end

  defp value({:enum, %{} = values}, key) when is_binary(key), do: Map.fetch(values, key)

  defp value({:enum, values}, value) when is_list(values),
    do: if(value in values, do: {:ok, value}, else: :error)

  defp value({:tuple, specs}, list) when is_list(list) and length(list) == length(specs) do
    Enum.zip(specs, list)
    |> Enum.reduce_while({:ok, []}, fn {spec, item}, {:ok, done} ->
      case value(spec, item) do
        {:ok, item} -> {:cont, {:ok, [item | done]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, items |> Enum.reverse() |> List.to_tuple()}
      :error -> :error
    end
  end

  defp value({:map, fields}, args) when is_map(args), do: fields(fields, args)
  defp value(_spec, _value), do: :error
end
