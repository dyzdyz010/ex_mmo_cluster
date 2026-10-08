defmodule GateServer.Npc.Skills do
  @moduledoc """
  全局系统功能：已配置技能的能力条目与 worker 入口。技能描述、参数接纳与执行由各 Skill 实现拥有。
  profile.skills 的键是作者定义的原子名；内置技能可省略 module，自定义技能显式给 module。
  生命周期、内部事件路由与取消由 Runtime 维护。这里不认识决策后端或模型供应商。
  """
  alias GateServer.Npc.Body

  @builtins %{
    build: GateServer.Npc.Skills.Build,
    design_house: GateServer.Npc.Skills.HouseDesign,
    gather: GateServer.Npc.Skills.Gather,
    wilderness: GateServer.Npc.Skills.Wilderness
  }
  @metrics %{request_count: 0, jev_request_count: 0}

  @doc """
  已配置技能的能力条目（group :skill，按名字排序；形状见 `GateServer.Npc.Abilities`）。参数 schema 原样取自技能的
  `definition/1`，参数透传给技能、由技能接纳；名字只取作者配置的原子，不把外部输入转成新原子。
  """
  def entries(profile) do
    for {name, config} <- Enum.sort(Map.get(profile, :skills, %{})) do
      definition = implementation(name, config).definition(profile)

      %{
        name: Atom.to_string(name),
        group: :skill,
        description: definition.description,
        done: "技能运行期间不再询问；结束时只回一个终态（verb 是技能名，data 是技能结果）。",
        params: {:skill, definition.parameters},
        build: fn args, _ -> %{verb: :skill, skill: name, args: args} end
      }
    end
  end

  @doc "启动受监视的技能进程；父进程接收 skill_finished 与普通 DOWN。observes = 技能是否逐帧读观察。"
  def start(body, command, profile, observation) do
    parent = self()

    observes =
      case Map.fetch(Map.get(profile, :skills, %{}), command.skill) do
        {:ok, config} -> GateServer.Npc.Skill.observes?(implementation(command.skill, config))
        :error -> false
      end

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

    %{pid: pid, ref: ref, command: command, observes: observes}
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
