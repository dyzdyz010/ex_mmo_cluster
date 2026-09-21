defmodule GateServer.Npc.Skills do
  @moduledoc """
  全局系统功能：通用大脑的长任务工具入口。一次调用在独立进程执行，结束才回一个结果。
  原子动作仍经 Body；内部命令身份为 {:skill, 调用号, 步骤号}，大脑只路由其事件，不逐步询问模型。
  可用技能和各自参数由 profile.skills 给出；取消与运行期间的 Jev 中断归父大脑。
  """
  alias GateServer.Npc.{Body, Brain.Llm}
  @names %{"design" => :design, "build" => :build, "wilderness" => :wilderness}
  @point %{type: "array", items: %{type: "integer"}, minItems: 3, maxItems: 3}
  @metrics %{request_count: 0, jev_request_count: 0}

  @doc "已配置的技能工具；所有原子动词仍由 Llm 独立提供。"
  def tools(profile) do
    definitions = [
      {:design, "多轮设计一栋住宅：在无界面工作台组合目录部件、修改宏格、查看并检查，成功返回已发布定义 id。不会放到地图上。",
       %{goal: %{type: "string"}, anchor_micro: @point, orientation: %{type: "integer", minimum: 0, maximum: 23}}, ["goal","anchor_micro","orientation"]},
      {:build, "将已发布的 definition 整体放到地图上，经现有 prefab_place 结算。锚点是 micro 坐标，1米=8micro；先走到工具射程内。",
       %{definition: %{type: "string"}, anchor_micro: @point, orientation: %{type: "integer", minimum: 0, maximum: 23}}, ["definition","anchor_micro","orientation"]},
      {:wilderness, "荒野逐格施工：给一句地形整理或铺路等目标，代码规划并逐格执行，最终报告世界实际还差什么。建筑优先用 design 和 build。",
       %{goal: %{type: "string"}, tool_id: %{type: "integer", enum: Map.keys(Map.get(profile,:tools,%{}))}}, ["goal","tool_id"]}
    ]
    for {name,description,properties,required} <- definitions, Map.has_key?(Map.get(profile,:skills,%{}),name),
      do: %{type: "function",name: Atom.to_string(name),description: description,
        parameters: %{type: "object",properties: properties,required: required,additionalProperties: false}}
  end

  @doc "模型工具名仅映射已有技能，不创建动态原子。参数交执行入口验证。"
  def command(name, args, id) do
    case Map.fetch(@names,name) do
      {:ok, skill} -> %{id: id,verb: :skill,skill: skill,args: args}
      :error -> nil
    end
  end

  @doc "启动受监视的技能进程；父进程接收 skill_finished 与普通 DOWN。"
  def start(body, command, profile, observation) do
    parent = self()
    {pid,ref} = :erlang.spawn_opt(fn ->
      result = with {:ok, context} <- Body.skill_context(body) do
        context = Map.merge(context,%{body: body,call_id: command.id,profile: profile,observation: observation,
          request: Map.get(profile,:request,&Llm.request/2)})
        run(context,command)
      else
        {:error, reason} -> {:error,reason,@metrics}
      end
      send(parent,{:skill_finished,command.id,result})
    end,[:link,:monitor])
    %{pid: pid,ref: ref,command: command}
  end

  @doc "执行一个已配置技能；技能收到的是同一正式会话的 World / Scene / actor。"
  def run(context, %{skill: skill,args: args}) do
    with {:ok, config} <- Map.fetch(Map.get(context.profile,:skills,%{}),skill),
         {:ok, args} <- arguments(skill,args) do
      execute(skill,context,config,args)
    else
      :error -> {:error,:skill_not_configured,@metrics}
      {:error, reason} -> {:error,reason,@metrics}
    end
  end

  defp execute(:build, context, _config, args) do
    Body.command(context.body,Map.merge(args,%{id: {:skill,context.call_id,1},verb: :prefab_place}))
    receive do
      {:outcome,%{id: 1,status: :done,data: data}} -> {:ok,Map.put(data,:metrics,@metrics)}
      {:outcome,%{id: 1,reason: reason}} -> {:error,reason,@metrics}
    after
      300_000 -> {:error,:body_timeout,@metrics}
    end
  end

  defp execute(:design, context, config, args) do
    GateServer.Npc.Skills.Design.run(Map.merge(context,%{endpoint: context.profile.endpoint,
      labels: Map.get(config,:labels,%{}),budget: Map.fetch!(config,:budget)}),args)
  end

  defp execute(:wilderness, context, config, args) do
    profile = Map.merge(config,%{cid: context.actor.cid,goal: args.goal,tool_id: args.tool_id,
      planner: context.profile.endpoint,scheduler: context.profile.scheduler,
      memory: Map.get(context.profile,:memory,DataService.NpcMemory),request: context.request})
    GateServer.Npc.Skills.Wilderness.run(%{context | profile: profile},args)
  end

  defp arguments(:build,%{"definition"=>text,"anchor_micro"=>anchor,"orientation"=>o}) when is_binary(text) do
    with {:ok, <<id::binary-size(32)>>} <- Base.decode16(text,case: :mixed),
         {:ok, anchor} <- anchor(anchor,o), do: {:ok,%{definition_id: id,anchor: anchor,orientation: o}},
         else: (_ -> {:error,:invalid_skill_arguments})
  end
  defp arguments(:design,%{"goal"=>goal,"anchor_micro"=>anchor,"orientation"=>o}) when is_binary(goal) and byte_size(goal)>0 do
    with {:ok, anchor} <- anchor(anchor,o), do: {:ok,%{goal: goal,anchor: anchor,orientation: o}}
  end
  defp arguments(:wilderness,%{"goal"=>goal,"tool_id"=>tool}=args) when is_binary(goal) and byte_size(goal)>0 and is_integer(tool) do
    parsed = %{goal: goal,tool_id: tool}
    {:ok,if(Map.has_key?(args,"ops"),do: Map.put(parsed,:ops,args["ops"]),else: parsed)}
  end
  defp arguments(_, _), do: {:error,:invalid_skill_arguments}
  defp anchor([x,y,z],o) when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(o) and o in 0..23,
    do: {:ok,{x,y,z}}
  defp anchor(_, _), do: {:error,:invalid_skill_arguments}
end
