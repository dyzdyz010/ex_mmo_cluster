defmodule GateServer.Npc.Skill do
  @moduledoc """
  全局系统功能：可替换技能契约。definition/1 描述当前参数；run/3 在 Runtime 的 worker 中执行。
  输入参数使用字符串键，接纳与失败语义由技能拥有。原子动作经 context.body，内部 id 为
  {:skill, context.call_id, step_id}；worker 收到的 Outcome 已由 Runtime 还原 step_id。
  返回一个终态与实际用量；任务未完成不得以空结果代替成功。取消后已提交事务不回滚。

  definition/1 的 parameters 原样投影为 LLM 的 strict 工具（`GateServer.Npc.Abilities.tools/1`），必须满足 strict：
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
