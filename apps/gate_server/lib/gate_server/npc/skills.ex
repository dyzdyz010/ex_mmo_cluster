defmodule GateServer.Npc.Skills do
  @moduledoc """
  全局系统功能：已配置技能的目录与 worker 入口。技能描述、参数接纳与执行由各 Skill 实现拥有。
  profile.skills 的键是作者定义的原子名；内置技能可省略 module，自定义技能显式给 module。
  生命周期、内部事件路由与取消由 Runtime 维护。这里不认识决策后端或模型供应商。
  """
  alias GateServer.Npc.Body

  @builtins %{
    build: GateServer.Npc.Skills.Build,
    design: GateServer.Npc.Skills.Design,
    wilderness: GateServer.Npc.Skills.Wilderness
  }
  @defaults %{skills: %{build: %{}, design: %{}, wilderness: %{}}}
  @metrics %{request_count: 0, jev_request_count: 0}

  @doc "已配置技能的能力描述；LLM 可以投影为工具，脚本可直接读取同一参数契约。"
  def tools(profile) do
    for {name, config} <- Enum.sort(Map.get(profile, :skills, %{})) do
      module = implementation(name, config)
      Map.merge(module.definition(profile), %{type: "function", name: Atom.to_string(name)})
    end
  end

  @doc "只从作者配置中匹配工具名，不创建外部输入原子；参数由技能接纳。"
  def command(name, args, id, profile \\ @defaults) do
    case Enum.find(Map.keys(Map.get(profile, :skills, %{})), &(Atom.to_string(&1) == name)) do
      nil -> nil
      skill -> %{id: id, verb: :skill, skill: skill, args: args}
    end
  end

  @doc "启动受监视的技能进程；父进程接收 skill_finished 与普通 DOWN。"
  def start(body, command, profile, observation) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            with {:ok, context} <- Body.skill_context(body) do
              context =
                Map.merge(context, %{
                  body: body,
                  call_id: command.id,
                  profile: profile,
                  observation: observation,
                  request: Map.get(profile, :request, &GateServer.Npc.Http.request/2)
                })

              run(context, command)
            else
              {:error, reason} -> {:error, reason, @metrics}
            end

          send(parent, {:skill_finished, command.id, result})
        end,
        [:link, :monitor]
      )

    %{pid: pid, ref: ref, command: command}
  end

  @doc "调用已配置技能，拒绝未配置的能力。"
  def run(context, %{skill: skill, args: args}) do
    case Map.fetch(Map.get(context.profile, :skills, %{}), skill) do
      {:ok, config} -> implementation(skill, config).run(context, args, config)
      :error -> {:error, :skill_not_configured, @metrics}
    end
  end

  defp implementation(name, config), do: Map.get(config, :module) || Map.fetch!(@builtins, name)
end
