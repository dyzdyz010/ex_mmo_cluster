defmodule NpcServer.Skill do
  @moduledoc """
  全局系统功能：可替换技能契约。definition/1 描述当前参数；run/3 在 Runtime 的 worker 中执行。
  输入参数使用字符串键，接纳与失败语义由技能拥有。原子动作经 context.body，内部 id 为
  {:skill, context.call_id, step_id}；worker 收到的 Outcome 已由 Runtime 还原 step_id。
  返回一个终态与实际用量；任务未完成不得以空结果代替成功。取消后已提交事务不回滚。

  definition/1 的 parameters 原样投影为 LLM 的 strict 工具（`NpcServer.Abilities.tools/1`），必须满足 strict：
  每个 object 都写 `additionalProperties: false`、全部属性列进 `required`，可空字段写 `type: [t, "null"]`。
  不满足时代理拒绝整个请求，配了这个技能的 NPC 每次询问都失败。
  """
  @type result :: {:ok, map()} | {:error, term(), map()}
  @callback definition(profile :: map()) :: %{description: String.t(), parameters: map()}
  @callback run(context :: map(), arguments :: map(), config :: map()) :: result()
  @doc "可选：返回 true 时 Runtime 把每个 Observation 转给 worker；不实现即不转发，worker 邮箱不会堆积观察。"
  @callback observations?() :: boolean()
  @optional_callbacks observations?: 0

  @doc "技能等一个 Body Outcome 的上限（毫秒）：Body 对每条命令都会回一个 Outcome，超时以 `body_timeout` 结束。"
  def body_timeout, do: 300_000

  @doc "`move_to` 被这些原因拒绝 = 去不了这个目标（Body 的寻路与单程上限），技能换下一个目标；其余拒绝原样作为终态。"
  def unreachable, do: [:no_path, :stuck, :too_far]

  @doc """
  技能内部的一步原子动作：编下一个步号，以 `{:skill, 调用号, 步号}` 交给 Body，等这一步的 Outcome（上限 `body_timeout/0`）。
  `state` 是技能自己的状态，至少有 `body`、`call`（调用号）与 `step`（上一个步号，从 0 起）。可选 `space`：一个技能在自己的
  调用里组合另一个技能（如 expand 调 gather）时，给被组合的那次一个步号命名空间，步号写成 `{space, n}`，同一调用号下的
  内部 id 不重复（Runtime 只按调用号路由，步号原样还给 worker）。返回 `{:ok, data, state}` 或 `{:error, 原因, state}`。
  """
  def call(state, command) do
    step = state.step + 1
    state = %{state | step: step}

    key =
      case Map.get(state, :space) do
        nil -> step
        space -> {space, step}
      end

    NpcServer.Body.command(state.body, Map.put(command, :id, {:skill, state.call, key}))

    receive do
      {:outcome, %{id: ^key, status: :done, data: data}} -> {:ok, data, state}
      {:outcome, %{id: ^key} = outcome} -> {:error, outcome.reason || outcome.status, state}
    after
      body_timeout() -> {:error, :body_timeout, state}
    end
  end

  @doc "技能实现是否声明逐帧读取 Observation。"
  def observes?(module) do
    Code.ensure_loaded!(module)
    function_exported?(module, :observations?, 0) and module.observations?()
  end

  @doc "设计与放置共用的 micro 锚点及朝向参数说明。"
  def placement_properties do
    %{
      anchor_micro: %{type: "array", items: %{type: "integer"}, minItems: 3, maxItems: 3},
      orientation: %{type: "integer", minimum: 0, maximum: 23}
    }
  end

  @doc "Prefab 技能共用的 micro 锚点与离散朝向接纳。"
  def anchor([x, y, z], orientation)
      when is_integer(x) and is_integer(y) and is_integer(z) and
             is_integer(orientation) and orientation in 0..23,
      do: {:ok, {x, y, z}}

  def anchor(_, _), do: {:error, :invalid_skill_arguments}
end
