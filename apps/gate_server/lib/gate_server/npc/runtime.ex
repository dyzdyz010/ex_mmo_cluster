defmodule GateServer.Npc.Runtime do
  @moduledoc """
  全局系统功能：所有 Brain 共用的命令与技能运行层。Body 是会话 owner，本层拥有技能生命周期。
  同步 Brain 输出与异步 Body.command/2 都经本层；原子动作仍由 Body 执行。
  技能内部 Outcome 不交给 Brain，每次调用只回一个终态。取消等待 worker 退出和权威 stop，
  不撤销已提交的事务。无 scheduler 配置的脚本不产生调度模型请求。
  """
  require Logger
  alias GateServer.Npc.{Body, Memory, Skills, Scheduler}

  @doc "在 Body 内建立运行进程；后端 init/1 的 self() 是共用命令接收端。"
  def init({backend, profile}) do
    body = self()

    spawn_link(fn ->
      Process.flag(:trap_exit, true)

      loop(%{
        body: body,
        backend: backend,
        mind: backend.init(profile),
        profile: profile,
        memory: Map.get(profile, :memory, DataService.NpcMemory),
        policy: Scheduler.configured(profile),
        observation: nil,
        skill: nil,
        heard: false
      })
    end)
  end

  @doc "转发 Body 的不可变事件，不阻塞移动输入。"
  def handle_event(event, runtime) do
    send(runtime, event)
    {[], runtime}
  end

  defp loop(state) do
    next =
      receive do
        {:observation, observation} ->
          if state.skill && state.skill.cancelling == nil,
            do: send(state.skill.pid, {:observation, observation})

          deliver(%{state | observation: observation}, {:observation, observation})

        {:outcome, %{id: {:skill, id, step}} = outcome} ->
          case state.skill do
            %{command: %{id: ^id}, cancelling: nil} = active ->
              send(active.pid, {:outcome, %{outcome | id: step}})
              state

            %{command: %{id: ^id}, cancelling: reason} when step == :stop ->
              reason =
                if outcome.status == :done,
                  do: reason,
                  else: {:stop_failed, outcome.status, outcome.reason}

              finish_skill(state, {:error, reason, %{request_count: nil, jev_request_count: nil}})

            _ ->
              state
          end

        {:outcome, outcome} ->
          deliver(state, {:outcome, outcome})

        {:heard, _} = event ->
          if state.skill, do: send(self(), {:skill_check, state.skill.command.id})
          deliver(%{state | heard: true}, event)

        {:"$gen_cast", {:command, command}} ->
          execute(state, command)

        {:skill_finished, id, result} ->
          case state.skill do
            %{command: %{id: ^id}, cancelling: nil} -> finish_skill(state, result)
            _ -> state
          end

        {:skill_check, id} ->
          check_skill(state, id)

        {:skill_verdict, id, verdict} ->
          decide_skill(state, id, verdict)

        {:DOWN, ref, :process, _pid, reason} ->
          case state.skill do
            %{ref: ^ref, cancelling: nil} ->
              finish_skill(
                state,
                {:error, {:skill_failed, exit_kind(reason)},
                 %{request_count: nil, jev_request_count: nil}}
              )

            %{ref: ^ref} = active ->
              Body.command(state.body, %{id: {:skill, active.command.id, :stop}, verb: :stop})
              state

            %{policy_ref: ^ref, cancelling: nil} when reason != :normal ->
              interrupt_skill(state, :scheduler_unavailable)

            _ ->
              state
          end

        {:EXIT, body, _} when body == state.body ->
          if state.skill, do: Process.exit(state.skill.pid, :shutdown)
          if is_pid(state.mind), do: Process.exit(state.mind, :shutdown)
          exit(:shutdown)

        {:EXIT, backend, reason} when backend == state.mind ->
          exit(reason)

        {:EXIT, _, _} ->
          state
      end

    loop(next)
  end

  defp deliver(state, event) do
    {commands, mind} = state.backend.handle_event(event, state.mind)
    Enum.reduce(commands, %{state | mind: mind}, &execute(&2, &1))
  end

  # 公共命令入口尚未收到正式观察时，没有可用的身份/位置上下文。
  defp execute(%{observation: nil} = state, %{verb: verb} = command)
       when verb in [:skill, :remember, :recall, :search_memory] do
    emit(state, %{
      id: command.id,
      verb: Map.get(command, :skill, verb),
      status: :rejected,
      reason: :invalid_session,
      data: nil
    })
  end

  defp execute(state, %{verb: :skill} = command), do: start_skill(state, command)

  defp execute(
         %{skill: %{command: %{id: id}, cancelling: nil}} = state,
         %{verb: :cancel_skill, id: id}
       ),
       do: interrupt_skill(state, :cancelled)

  defp execute(state, %{verb: :cancel_skill}), do: state

  defp execute(state, %{verb: verb} = command)
       when verb in [:remember, :recall, :search_memory] do
    actor = state.observation.self
    emit(state, Memory.execute(state.memory, actor.entity_id, actor.position, command))
  end

  defp execute(state, command) do
    Body.command(state.body, command)
    state
  end

  defp emit(state, outcome) do
    send(state.body, {:npc_runtime_outcome, outcome})
    deliver(state, {:outcome, outcome})
  end

  defp schedule(profile, id) do
    if Scheduler.configured(profile) != nil,
      do: Process.send_after(self(), {:skill_check, id}, 10_000)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp start_skill(%{skill: nil} = state, command) do
    active = Skills.start(state.body, command, state.profile, state.observation)
    timer = schedule(state.profile, command.id)

    %{
      state
      | skill:
          Map.merge(active, %{
            timer: timer,
            cancelling: nil,
            policy_ref: nil,
            policy_pid: nil,
            jev_requests: 0,
            scheduler_requests: 0
          })
    }
  end

  defp start_skill(state, command),
    do:
      emit(state, %{
        id: command.id,
        verb: command.skill,
        status: :rejected,
        reason: :skill_busy,
        data: nil
      })

  defp check_skill(%{policy: nil} = state, _), do: state

  defp check_skill(
         %{skill: %{command: %{id: id}, cancelling: nil, policy_ref: nil} = active} = state,
         id
       ) do
    parent = self()
    {module, config} = state.policy
    context = %{skill: active.command.skill, observation: state.observation, heard: state.heard}

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result = module.decide(context, config)

          send(parent, {:skill_verdict, id, result})
        end,
        [:link, :monitor]
      )

    %{
      state
      | skill: %{
          active
          | policy_ref: ref,
            policy_pid: pid,
            scheduler_requests: active.scheduler_requests + 1,
            jev_requests: active.jev_requests + if(module == GateServer.Npc.Jev, do: 1, else: 0)
        }
    }
  end

  defp check_skill(state, _), do: state

  defp decide_skill(
         %{skill: %{command: %{id: id}, cancelling: nil} = active} = state,
         id,
         verdict
       ) do
    Process.demonitor(active.policy_ref, [:flush])
    state = %{state | skill: %{active | policy_ref: nil, policy_pid: nil}}

    case verdict do
      :continue ->
        cancel_timer(active.timer)
        timer = schedule(state.profile, id)
        %{state | skill: %{state.skill | timer: timer}}

      {:interrupt, reason} ->
        interrupt_skill(state, {:interrupted, reason})

      {:error, _} ->
        interrupt_skill(state, :scheduler_unavailable)
    end
  end

  defp decide_skill(state, _, _), do: state

  defp interrupt_skill(%{skill: active} = state, reason) do
    cancel_timer(active.timer)
    Process.exit(active.pid, :shutdown)

    # DOWN 后才发 stop；它不能撤销已提交的世界事务，只有权威 done 才确认停止。
    %{state | skill: %{active | cancelling: reason}}
  end

  defp finish_skill(%{skill: active} = state, result) do
    cancel_timer(active.timer)
    Process.demonitor(active.ref, [:flush])
    if active.policy_pid, do: Process.exit(active.policy_pid, :shutdown)
    if active.policy_ref, do: Process.demonitor(active.policy_ref, [:flush])

    {status, reason, data} =
      case result do
        {:ok, data} -> {:done, nil, data}
        {:error, reason, metrics} -> {:rejected, reason, %{metrics: metrics}}
      end

    # 子进程未返回统计时保留未知；父脑自己发出的 Jev 次数始终确知。
    metrics =
      Map.update(Map.get(data, :metrics, %{}), :jev_request_count, active.jev_requests, fn
        nil -> nil
        count -> count + active.jev_requests
      end)
      |> Map.put(:parent_jev_request_count, active.jev_requests)
      |> Map.put(:scheduler_request_count, active.scheduler_requests)

    data = Map.put(data, :metrics, metrics)

    # 统一记录调用的终态；技能内部的领域经历仍由技能拥有，取消/崩溃也不会漏掉调用记录。
    actor = state.observation.self

    experience =
      "Skill #{active.command.skill}: status=#{status}; reason=#{inspect(reason)}; " <>
        "request=#{inspect(active.command.args, limit: 20, printable_limit: 350)}; " <>
        "last_check=#{inspect(Map.get(metrics, :last_check), limit: 30, printable_limit: 500)}; " <>
        "result=#{inspect(Map.take(data, [:definition_id, :seq, :instance_id]), limit: 10)}"

    data =
      case Memory.journal(
             state.memory,
             actor.entity_id,
             String.slice(experience, 0, 1500),
             actor.position
           ) do
        {:ok, _} -> data
        {:error, error} -> Map.put(data, :memory_error, error)
      end

    Logger.info(
      "npc_skill_outcome skill=#{active.command.skill} status=#{status} metrics=#{inspect(metrics)}"
    )

    emit(%{state | skill: nil, heard: false}, %{
      id: active.command.id,
      verb: active.command.skill,
      status: status,
      reason: reason,
      data: data
    })
  end

  defp exit_kind({%{__struct__: module}, _}), do: module
  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_), do: :worker_failed
end
