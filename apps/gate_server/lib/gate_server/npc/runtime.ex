defmodule GateServer.Npc.Runtime do
  @moduledoc """
  全局系统功能：所有 Brain 共用的命令与技能运行层。Body 是会话 owner，本层拥有技能生命周期。
  同步 Brain 输出与异步 Body.command/2 都经本层；原子动作仍由 Body 执行。
  技能内部 Outcome 不交给 Brain，每次调用只回一个终态。取消等待 worker 退出，再等 Body 的 settle 停止：
  移动停稳且该技能已投递的世界调用全部有了结果，终态之后不再有这次调用引起的世界变化。
  取消期间到达的技能内部结果原样放进终态的 `settled`，已提交的事务不撤销、也不隐瞒。
  中断策略只来自 `profile.interrupt_policy`；策略失败只记一笔，不中断正在进行的技能。
  """
  require Logger
  alias GateServer.Npc.{Body, Memory, Skills, Scheduler}

  # 中断检查间隔；技能进行中保留最近这么多句玩家话语交给中断策略。
  @check_ms 10_000
  @heard 5
  @unknown_metrics %{request_count: nil, jev_request_count: nil}

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
        # 当前技能开始后听到的话（新在前），只交给中断策略；技能结束即清空。
        heard: []
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
          # 只给声明要逐帧观察的技能转发；其余技能不读邮箱里的观察，转发只会堆积。
          case state.skill do
            %{cancelling: nil, observes: true, pid: pid} -> send(pid, {:observation, observation})
            _ -> :ok
          end

          deliver(%{state | observation: observation}, {:observation, observation})

        {:outcome, %{id: {:skill, id, step}} = outcome} ->
          case state.skill do
            %{command: %{id: ^id}, cancelling: nil} = active ->
              send(active.pid, {:outcome, %{outcome | id: step}})
              state

            %{command: %{id: ^id}} when step == :stop ->
              settle_skill(state, outcome)

            # 取消已请求、终态未发：结果仍是这次调用造成的，记进终态。
            %{command: %{id: ^id}} = active ->
              settled = active.settled ++ [Map.delete(outcome, :id)]
              %{state | skill: %{active | settled: settled}}

            _ ->
              state
          end

        {:outcome, outcome} ->
          deliver(state, {:outcome, outcome})

        {:heard, message} = event ->
          if state.skill, do: send(self(), {:skill_check, state.skill.command.id})
          deliver(%{state | heard: Enum.take([message | state.heard], @heard)}, event)

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
              finish_skill(state, {:error, {:skill_failed, exit_kind(reason)}, @unknown_metrics})

            # worker 已退出，不会再投新命令；请 Body 停下并等它在途的世界调用都有结果。
            %{ref: ^ref} = active ->
              Body.command(state.body, %{
                id: {:skill, active.command.id, :stop},
                verb: :stop,
                settle: active.command.id
              })

              state

            %{policy_ref: ^ref, cancelling: nil} = active when reason != :normal ->
              check_failed(%{state | skill: %{active | policy_ref: nil, policy_pid: nil}}, {
                :policy_exited,
                exit_kind(reason)
              })

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

  # 取消命令有自己的 id 与 Outcome（受理与否）；被取消的技能仍以原调用号回一个终态。
  defp execute(state, %{verb: :cancel_skill} = command) do
    call = Map.get(command, :call)

    case state.skill do
      %{command: %{id: ^call}, cancelling: nil} ->
        state = interrupt_skill(state, :cancelled)

        emit(state, %{
          id: command.id,
          verb: :cancel_skill,
          status: :done,
          reason: nil,
          data: %{call: call}
        })

      %{command: %{id: ^call}} ->
        emit(state, %{
          id: command.id,
          verb: :cancel_skill,
          status: :rejected,
          reason: :already_cancelling,
          data: %{call: call}
        })

      _ ->
        emit(state, %{
          id: command.id,
          verb: :cancel_skill,
          status: :rejected,
          reason: :no_active_skill,
          data: %{call: call}
        })
    end
  end

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

  defp schedule(%{policy: nil}, _id), do: nil
  defp schedule(_state, id), do: Process.send_after(self(), {:skill_check, id}, @check_ms)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp start_skill(%{skill: nil} = state, command) do
    active = Skills.start(state.body, command, state.profile, state.observation)

    %{
      state
      | heard: [],
        skill:
          Map.merge(active, %{
            timer: schedule(state, command.id),
            cancelling: nil,
            settled: [],
            policy_ref: nil,
            policy_pid: nil,
            jev_requests: 0,
            scheduler_requests: 0,
            scheduler_errors: 0
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
      :continue -> reschedule(state)
      {:interrupt, reason} -> interrupt_skill(state, {:interrupted, reason})
      {:error, reason} -> check_failed(state, reason)
    end
  end

  defp decide_skill(state, _, _), do: state

  # 中断策略回答不了不等于该中断：技能照常进行，下次再查；失败次数随终态计量报告。
  defp check_failed(%{skill: active} = state, reason) do
    Logger.warning(
      "npc_interrupt_check_failed skill=#{active.command.skill} reason=#{inspect(reason)}"
    )

    reschedule(%{state | skill: %{active | scheduler_errors: active.scheduler_errors + 1}})
  end

  defp reschedule(%{skill: active} = state) do
    cancel_timer(active.timer)
    %{state | skill: %{active | timer: schedule(state, active.command.id)}}
  end

  defp interrupt_skill(%{skill: active} = state, reason) do
    cancel_timer(active.timer)
    if active.policy_pid, do: Process.exit(active.policy_pid, :shutdown)
    if active.policy_ref, do: Process.demonitor(active.policy_ref, [:flush])
    Process.exit(active.pid, :shutdown)

    # DOWN 后才发 settle 停止；它不能撤销已提交的世界事务，只有权威 done 才确认停止。
    %{state | skill: %{active | cancelling: reason, policy_ref: nil, policy_pid: nil}}
  end

  defp settle_skill(%{skill: active} = state, stop) do
    reason =
      if stop.status == :done,
        do: active.cancelling,
        else: {:stop_failed, stop.status, stop.reason}

    finish_skill(state, {:error, reason, @unknown_metrics})
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
      |> Map.put(:scheduler_error_count, active.scheduler_errors)

    data = Map.put(data, :metrics, metrics)
    data = if active.settled == [], do: data, else: Map.put(data, :settled, active.settled)

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

    emit(%{state | skill: nil, heard: []}, %{
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
