defmodule NpcServer.Runtime do
  @moduledoc """
  全局系统功能：所有 Brain 共用的命令与技能运行层。Body 是会话 owner，本层拥有技能生命周期。
  同步 Brain 输出与异步 Body.command/2 都经本层；原子动作仍由 Body 执行。
  技能内部 Outcome 不交给 Brain，每次调用只回一个终态。取消等待 worker 退出，再等 Body 的 settle 停止：
  移动停稳且该技能已投递的世界调用全部有了结果，终态之后不再有这次调用引起的世界变化。
  取消期间到达的技能内部结果原样放进终态的 `settled`，已提交的事务不撤销、也不隐瞒。
  中断策略只来自 `profile.interrupt_policy`；策略失败只记一笔，不中断正在进行的技能。
  统一居民采集时，Runtime 准入每个 Gather 步骤。玩家定向来话可在原步骤结算后暂停一次，回复仍交 Scene。
  对话处理结束放行原 worker 的下一步，保持原调用与采集状态。
  活动选择（`choose_activity` 命令，`NpcServer.Selector`）也在这里受理：本层持有选择器状态，在独立 worker 里向 Life 读心智
  （含按处境分路的记忆召回，至多 4 路，见 `Mind.recall_queries/2`）再问 Jev，应答以同一命令号的 Outcome 回给 Brain（done 的 data 是 `%{activity: 候选名}`；心智读不到、
  发问失败或 worker 崩溃是 rejected）。等应答期间本进程照常处理观察与其他命令。
  选定一项新活动时本层通知 Life 这项活动开始了（`Life.activity_started/1`，Life 从此记期间谁靠近过）；
  一项活动结束时（下一个 `choose_activity` 带来它的结局）本层把“做了什么、结果如何”与候选登记的地名作为一条经历交给 Life
  （`Life.activity/2`，`Selector.experience/2` 的结果）。上一项经历保存成功后才发问；失败由 Life 保留同一输入继续提交。
  `choose_activity` 自己的 Outcome 是选择器内部往来，不是经历。
  """
  require Logger
  alias NpcServer.{Body, Dialogue, Memory, Selector, Skills, Scheduler}
  alias NpcServer.Skills.Speak

  # 中断检查间隔；对话尾部不属于技能生命周期。
  @check_ms 10_000
  @unknown_metrics %{request_count: nil, jev_request_count: nil}

  @doc "在 Body 内建立运行进程；后端 init/1 的 self() 是共用命令接收端。"
  def init(brain, context \\ nil)

  def init({backend, profile}, context) do
    body = self()

    spawn_link(fn ->
      Process.flag(:trap_exit, true)

      life =
        if Map.has_key?(profile, :life) do
          life_profile =
            update_in(profile.life, &Map.put(&1, :appraise, backend == NpcServer.Brain.Llm))

          {:ok, life} = NpcServer.Life.start_link(self(), context, life_profile)
          life
        end

      loop(%{
        body: body,
        context: context,
        backend: backend,
        mind: backend.init(profile),
        life: life,
        life_state: nil,
        life_thanks: 0,
        profile: profile,
        memory: Map.get(profile, :memory, DataService.NpcMemory),
        policy: Scheduler.configured(profile),
        observation: nil,
        skill: nil,
        # 选择器状态（正在做的活动与最近几次选择）；在途的一次发问 `%{id: 命令号, ref: worker 的 monitor}`。
        select: Selector.new(),
        selecting: nil,
        # 按权威接收顺序保留本人、直接与旁听发言。
        heard: []
      })
    end)
  end

  @doc "转发 Body 的不可变事件，不阻塞移动输入。"
  def handle_event(event, runtime) do
    send(runtime, event)
    {[], runtime}
  end

  @doc "读取近期对话、正在进行的技能与选择器状态（`select`，形状见 `NpcServer.Selector`）；不触发决策或外部调用。"
  def observe(runtime), do: GenServer.call(runtime, :observe)

  defp loop(state) do
    next =
      receive do
        {:"$gen_call", from, {:step, observer, tag, context}} ->
          GenServer.reply(from, step(state, observer, tag, context))
          state

        {:step_body, from, observer, tag, context} ->
          GenServer.reply(from, step(state, observer, tag, context))
          state

        {:observation, observation} ->
          now = System.system_time(:millisecond)

          observation =
            observation
            |> Map.put(:heard, state.heard)
            |> Map.put(:world_time, MmoContracts.WorldTime.at(now * 1000))

          if state.life, do: NpcServer.Life.observation(state.life, observation)

          observation =
            if state.life_state do
              observation
              |> Map.put(:life, %{state: state.life_state, now_ms: now, thanks: state.life_thanks})
              |> Map.put(:mind, NpcServer.Life.State.view(state.life_state, now))
            else
              observation
            end

          # 只给声明要逐帧观察的技能转发；其余技能不读邮箱里的观察，转发只会堆积。
          case state.skill do
            %{cancelling: nil, observes: true, pid: pid} -> send(pid, {:observation, observation})
            _ -> :ok
          end

          deliver(%{state | observation: observation}, {:observation, observation})

        :observation_lost ->
          if state.life, do: NpcServer.Life.observation_lost(state.life)
          lose_gather_reply(state)

        {:life_state, canonical, thanks} ->
          %{state | life_state: canonical, life_thanks: thanks}

        {:outcome, %{id: {:skill, id, step}} = outcome} ->
          skill_outcome(state, id, step, outcome)

        {:outcome, outcome} ->
          deliver(state, {:outcome, outcome})

        {kind, message} when kind in [:heard, :said] ->
          if state.life, do: NpcServer.Life.speech(state.life, message)
          heard = Dialogue.append(state.heard, message)
          state = deliver(%{state | heard: heard}, {:dialogue, heard})
          cid = state.observation && state.observation.self.entity_id

          if kind == :heard and Dialogue.direct?(message, cid) do
            state
            |> request_gather_reply(message)
            |> deliver({:heard, message})
          else
            state
          end

        {:"$gen_call", from, :observe} ->
          GenServer.reply(from, %{
            heard: state.heard,
            skill: state.skill && state.skill.command,
            skill_boundary: observe_boundary(state.skill),
            select: state.select
          })

          state

        {:observe_body, from, snapshot} ->
          GenServer.reply(
            from,
            snapshot
            |> Map.put(:dialogue, state.heard)
            |> Map.put(:skill_boundary, observe_boundary(state.skill))
            |> Map.put(:select, state.select)
          )

          state

        {:"$gen_cast", {:command, command}} ->
          execute(state, command)

        {:skill_step, worker, command} ->
          gather_step(state, worker, command)

        {:gather_reply, worker, result} ->
          finish_reply_choice(state, worker, result)

        {:gather_reply_timeout, worker} ->
          finish_reply_choice(state, worker, {:error, :timeout})

        {:skill_finished, id, result} ->
          case state.skill do
            %{command: %{id: ^id}, cancelling: nil} -> finish_skill(state, result)
            _ -> state
          end

        {:skill_check, id} ->
          check_skill(state, id)

        {:skill_verdict, id, verdict} ->
          decide_skill(state, id, verdict)

        # 发问 worker 读完心智、发 Jev 请求之前报来的“这次问的是什么”；它一定先于同一个 worker 的结果与 DOWN 到达。
        {:select_asked, question} ->
          %{state | select: Selector.asked(state.select, question)}

        {:select_finished, id, result} ->
          case state.selecting do
            %{id: ^id, ref: ref} ->
              Process.demonitor(ref, [:flush])
              finish_select(state, result)

            _ ->
              state
          end

        # 发问 worker 没交结果就退出（如应答不是 JSON）：同样是一次显式失败，不让树一直等。
        {:DOWN, ref, :process, _pid, reason}
        when is_map(state.selecting) and ref == state.selecting.ref ->
          finish_select(state, {:error, {:select_worker_failed, exit_kind(reason)}})

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

            %{boundary: %{pause: {:deciding, _, _, %{ref: ^ref, pid: worker}}}} ->
              finish_reply_choice(
                state,
                worker,
                {:error, {:reply_worker_failed, exit_kind(reason)}}
              )

            _ ->
              state
          end

        {:EXIT, body, _} when body == state.body ->
          if state.life, do: Process.exit(state.life, :shutdown)
          if state.skill, do: Process.exit(state.skill.pid, :shutdown)
          if is_pid(state.mind), do: Process.exit(state.mind, :shutdown)
          exit(:shutdown)

        {:EXIT, backend, reason} when backend == state.mind ->
          exit(reason)

        {:EXIT, life, reason} when life == state.life ->
          exit(reason)

        {:EXIT, _, _} ->
          state
      end

    loop(next)
  end

  # 只转发许可；在途模型与命令仍由同一个 Brain owner 管理。
  defp step(%{backend: NpcServer.Brain.Llm, mind: mind}, observer, tag, context),
    do: NpcServer.Brain.Llm.step(mind, observer, tag, context)

  defp step(_, _, _, _), do: {:error, :unsupported_backend}

  defp deliver(state, event) do
    if state.life do
      case event do
        {:outcome, outcome} -> NpcServer.Life.experience(state.life, outcome)
        _ -> :ok
      end
    end

    {commands, mind} = state.backend.handle_event(event, state.mind)

    if state.life != nil and state.backend == NpcServer.Brain.Social,
      do:
        NpcServer.Life.decision(
          state.life,
          Map.take(mind, [:social, :last_outcome, :thanks])
        )

    Enum.reduce(commands, %{state | mind: mind}, &execute(&2, &1))
  end

  # 公共命令入口尚未收到正式观察时，没有可用的身份/位置上下文。
  defp execute(%{observation: nil} = state, %{verb: verb} = command)
       when verb in [:skill, :remember, :recall, :search_memory, :set_plan] do
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
       when verb in [:remember, :recall, :search_memory, :set_plan] do
    actor = state.observation.self
    emit(state, Memory.execute(state.memory, actor.entity_id, actor.position, command))
  end

  # 活动选择：先记下上一项活动的结局，再在独立 worker 里发问（Life 的读取、记忆召回与 Jev 请求都不阻塞本进程）。
  # 同一时刻只有一次发问：树只有一个 choose_activity 叶子，拿到它的 Outcome 之前不会再发。
  defp execute(state, %{verb: :choose_activity} = command) do
    {trigger, select} = Selector.ended(state.select, command.ended)
    parent = self()
    %{profile: profile, observation: observation} = state
    history = Selector.history(select)

    # 经历是“做了什么、结果如何”：一项活动刚结束时记一条。发问失败后的重问（retry）带的是同一份报告，不再记。
    experience = if trigger in ["completed", "failed"], do: Selector.experience(select, profile)
    life = state.life

    {_pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            with :ok <- record_experience(life, experience),
                 {:ok, question} <-
                   Selector.question(profile, observation, history, state.context) do
              send(parent, {:select_asked, question})
              Selector.ask(profile, question, trigger)
            end

          send(parent, {:select_finished, command.id, result})
        end,
        [:link, :monitor]
      )

    %{state | select: select, selecting: %{id: command.id, ref: ref}}
  end

  defp execute(state, command) do
    Body.command(state.body, command)
    state
  end

  defp record_experience(_life, nil), do: :ok
  defp record_experience(life, experience), do: NpcServer.Life.activity(life, experience)

  defp finish_select(%{selecting: %{id: id}} = state, result) do
    cid = state.observation.self.entity_id

    {select, outcome} =
      case result do
        {:ok, selection} ->
          # 新活动从这里开始：Life 从此记它期间谁靠近过，结束时写进这项活动的经历。
          NpcServer.Life.activity_started(state.life)

          data = %{activity: selection.activity}

          data =
            if selection[:topic], do: Map.put(data, :speech, selection.topic.target), else: data

          {Selector.chose(state.select, selection, state.profile, cid),
           %{status: :done, reason: nil, data: data}}

        {:error, reason} ->
          {Selector.failed(state.select, reason, cid),
           %{status: :rejected, reason: reason, data: nil}}
      end

    emit(
      %{state | select: select, selecting: nil},
      Map.merge(outcome, %{id: id, verb: :choose_activity})
    )
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
    mind_snapshot = if command.skill == :speak, do: get_in(state.select, [:asked, :state])
    step_owner = gather_step_owner(state, command)

    active =
      Skills.start(
        state.body,
        command,
        state.profile,
        state.observation,
        mind_snapshot,
        step_owner
      )

    %{
      state
      | skill:
          Map.merge(active, %{
            boundary: if(step_owner, do: %{issued: nil, settled: nil, pause: nil}),
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

  defp gather_step_owner(
         %{
           backend: NpcServer.Brain.Tree,
           profile: %{activities: _, skills: %{speak: _}},
           life: life
         },
         %{skill: :gather}
       )
       when is_pid(life),
       do: self()

  defp gather_step_owner(_, _), do: nil

  defp skill_outcome(state, id, step, outcome) do
    case state.skill do
      %{command: %{id: ^id}, cancelling: nil, boundary: nil} = active ->
        send(active.pid, {:outcome, %{outcome | id: step}})
        state

      %{command: %{id: ^id}, cancelling: nil, boundary: %{issued: ^step} = boundary} = active ->
        send(active.pid, {:outcome, %{outcome | id: step}})
        %{state | skill: %{active | boundary: %{boundary | issued: nil, settled: step}}}

      %{
        command: %{id: ^id},
        cancelling: nil,
        boundary: %{
          pause: {:speaking, %{conversation_id: conversation, turn: turn} = speech, held}
        }
      } = active
      when step == {:reply, conversation, turn} ->
        resume_gather(state, active, speech, held, {outcome.status, outcome.reason})

      %{command: %{id: ^id}, cancelling: reason} when reason != nil and step == :stop ->
        settle_skill(state, outcome)

      # 取消已请求、终态未发，先把这次调用已提交的结果留在结束凭证。
      %{command: %{id: ^id}, cancelling: reason} = active when reason != nil ->
        settled = active.settled ++ [Map.delete(outcome, :id)]
        %{state | skill: %{active | settled: settled}}

      _ ->
        state
    end
  end

  defp request_gather_reply(
         %{skill: %{cancelling: nil, boundary: %{pause: nil} = boundary} = active} = state,
         %{speaker_kind: 0} = speech
       ) do
    log_boundary(state, active, speech, :received, step: boundary.issued)
    %{state | skill: %{active | boundary: %{boundary | pause: {:requested, speech}}}}
  end

  defp request_gather_reply(%{skill: %{command: %{id: id}, boundary: nil}} = state, _) do
    send(self(), {:skill_check, id})
    state
  end

  defp request_gather_reply(state, _), do: state

  defp gather_step(state, worker, %{id: {:skill, id, _}} = command) do
    case state.skill do
      %{pid: ^worker, command: %{id: ^id}, cancelling: nil, boundary: %{issued: nil, pause: nil}} =
          active ->
        dispatch_gather_step(state, active, command)

      %{
        pid: ^worker,
        command: %{id: ^id},
        cancelling: nil,
        boundary: %{issued: nil, pause: {:requested, speech}}
      } = active ->
        start_reply_choice(state, active, speech, command)

      _ ->
        state
    end
  end

  defp dispatch_gather_step(state, active, %{id: {:skill, _, step}} = command) do
    Body.command(state.body, command)
    %{state | skill: %{active | boundary: %{active.boundary | issued: step, pause: nil}}}
  end

  defp start_reply_choice(state, active, speech, %{id: {:skill, _, step}} = held) do
    parent = self()
    %{profile: profile, observation: observation} = state
    history = Selector.history(state.select)

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          send(
            parent,
            {:gather_reply, self(), choose_reply(profile, observation, history, speech)}
          )
        end,
        [:link, :monitor]
      )

    # 对话空闲到期前只给决策和写作一个有界窗口，已发给 Scene 的请求继续等 Body 返回。
    timer =
      Process.send_after(
        self(),
        {:gather_reply_timeout, pid},
        SceneServer.Dialogue.limits().idle_ms
      )

    log_boundary(state, active, speech, :paused, held_step: step)

    pause = {:deciding, speech, held, %{pid: pid, ref: ref, timer: timer}}
    %{state | skill: %{active | boundary: %{active.boundary | pause: pause}}}
  end

  defp choose_reply(profile, observation, history, speech) do
    with {:ok, question} <- Selector.gather_reply_question(profile, observation, history, speech),
         {:ok, choice} <- Selector.ask(profile, question, "gather_reply") do
      case choice.activity do
        "continue" -> :continue
        "reply" -> Speak.reply(profile, question.state, speech)
      end
    end
  end

  defp finish_reply_choice(
         %{
           skill:
             %{
               cancelling: nil,
               boundary: %{pause: {:deciding, speech, held, %{pid: worker} = task}}
             } = active
         } = state,
         worker,
         result
       ) do
    stop_reply_worker(task)

    case result do
      {:ok, command, metrics} ->
        id = {:skill, active.command.id, {:reply, speech.conversation_id, speech.turn}}
        log_boundary(state, active, speech, :reply, metrics: metrics)
        Body.command(state.body, Map.put(command, :id, id))

        %{
          state
          | skill: %{active | boundary: %{active.boundary | pause: {:speaking, speech, held}}}
        }

      {:error, reason, metrics} ->
        resume_gather(state, active, speech, held, {reason, metrics})

      other ->
        resume_gather(state, active, speech, held, other)
    end
  end

  defp finish_reply_choice(state, _, _), do: state

  defp resume_gather(state, active, speech, %{id: {:skill, _, step}} = held, result) do
    log_boundary(state, active, speech, :resumed, step: step, result: result)
    dispatch_gather_step(state, active, held)
  end

  defp lose_gather_reply(%{skill: %{cancelling: nil, boundary: %{pause: pause}}} = state)
       when pause != nil,
       do: interrupt_skill(state, :session_lost)

  defp lose_gather_reply(state), do: state

  defp stop_reply_worker(%{pid: pid, ref: ref, timer: timer}) do
    cancel_timer(timer)
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :shutdown)
  end

  defp cancel_gather_reply(%{boundary: %{pause: {:deciding, _, _, task}}}),
    do: stop_reply_worker(task)

  defp cancel_gather_reply(_), do: :ok

  defp observe_boundary(%{
         command: %{id: id},
         boundary: %{issued: issued, settled: settled, pause: pause}
       }) do
    view = %{call: id, issued_step: issued, settled_step: settled}

    case pause do
      nil -> Map.put(view, :phase, :working)
      {:requested, speech} -> Map.merge(view, pause_view(:requested, speech, nil))
      {:deciding, speech, held, _} -> Map.merge(view, pause_view(:deciding, speech, held))
      {:speaking, speech, held} -> Map.merge(view, pause_view(:speaking, speech, held))
    end
  end

  defp observe_boundary(_), do: nil

  defp pause_view(phase, speech, held) do
    %{
      phase: phase,
      held_step: if(held, do: elem(held.id, 2)),
      conversation_id: speech.conversation_id,
      turn: speech.turn,
      speaker_id: speech.speaker_id,
      speaker_epoch: speech.speaker_epoch
    }
  end

  defp log_boundary(state, active, speech, event, details) do
    fields = Enum.map_join(details, " ", fn {key, value} -> "#{key}=#{inspect(value)}" end)

    Logger.info(
      "npc_skill_boundary cid=#{state.observation.self.entity_id} call=#{inspect(active.command.id)} " <>
        "event=#{event} conversation_id=#{speech.conversation_id} turn=#{speech.turn} " <>
        "speaker_id=#{speech.speaker_id} speaker_epoch=#{speech.speaker_epoch} " <>
        "settled_step=#{inspect(active.boundary.settled)} #{fields}"
    )
  end

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
            jev_requests: active.jev_requests + if(module == NpcServer.Jev, do: 1, else: 0)
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
    cancel_gather_reply(active)
    if active.policy_pid, do: Process.exit(active.policy_pid, :shutdown)
    if active.policy_ref, do: Process.demonitor(active.policy_ref, [:flush])
    Process.exit(active.pid, :shutdown)

    # DOWN 后才发 settle 停止；它不能撤销已提交的世界事务，只有权威 done 才确认停止。
    boundary = if active.boundary, do: %{active.boundary | pause: nil}

    %{
      state
      | skill: %{
          active
          | boundary: boundary,
            cancelling: reason,
            policy_ref: nil,
            policy_pid: nil
        }
    }
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
    cancel_gather_reply(active)
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

    emit(%{state | skill: nil}, %{
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
