defmodule NpcServer.Life do
  @moduledoc """
  NPC 人生状态唯一 owner，跟随 Runtime 生命周期。canonical 心智、World 游标、待写经历与认识缓存
  原子保存在 NpcMemory 的 life/state 行；观察只派生衰减视图。World 读取与 Hindsight 使用独立 worker，
  慢记忆写入期间继续接纳权威事件。短经历先封成约 3000 字片段，失败重用原片段 id。
  World 事件只带被动那一格所属建筑的定义 id（`prefab`）；读取 worker 向 World 的发布元信息查出名字写进事件（`building`），
  经历原文由此说得出是哪座建筑（写法见 `Life.State`）。没有名字的定义与散格不点名。
  对话只接纳已发生的 Speech，以 conversation_id/turn 标识来源，不改 World 游标或心智数值；
  初次加载与存储失败期间保留未落盘输入，并以 unsaved_speech/error 显式呈现。
  CLI observe/flush/refresh/context 以永久 cid 定位本节点 owner；网络调用不会占用 Body 邮箱。
  统一形态（注册表 `"npc"`，规则模式）经两个入口用它：`mind/2` 是心智快照的只读视图（情绪与关系、还没写进 Hindsight 的
  经历原文、缓存认识与一次召回），`activity/2` 接纳“做了什么、结果如何”的活动经历。统一形态不读状态里的
  `traits`（`caution` / `sociability`）：人格只来自人格卡，这两个值并入人格卡待做。
  """
  use GenServer
  require Logger
  alias NpcServer.{Dialogue, Memory, Life.State, Life.Hindsight}
  alias NpcServer.Life.Appraisal
  @fragment_chars 3000
  @refresh_ms 600_000
  # 心智快照那一次召回的单次请求超时（毫秒）；写入与认识刷新仍用适配器的长超时。
  @mind_recall_timeout_ms 10_000

  @doc "由 Runtime 建立关联 owner；context 包含 cid、scene_id 和路由模块。"
  def start_link(owner, context, profile) do
    case GenServer.start_link(__MODULE__, {owner, context, profile}, name: name(context.cid)) do
      {:error, {:already_started, previous}} ->
        # Body transient 重启可以先于旧 Runtime 的关联进程退出；只等其真实退出，不复用旧 owner。
        ref = Process.monitor(previous)

        receive do
          {:DOWN, ^ref, :process, ^previous, _} ->
            GenServer.start_link(__MODULE__, {owner, context, profile}, name: name(context.cid))
        after
          5000 ->
            Process.demonitor(ref, [:flush])
            {:error, :life_owner_busy}
        end

      result ->
        result
    end
  end

  @doc "读取派生心智、持久游标、批写状态、缓存年龄和显式错误。"
  def observe(cid), do: call(cid, :observe)
  @doc "封存不足 3000 字的尾片段并后台批写；立即返回任务状态。"
  def flush(cid), do: call(cid, :flush)
  @doc "后台刷新四份认识；立即返回任务状态，决策不会调用此入口。"
  def refresh(cid), do: call(cid, :refresh)
  @doc "读取缓存认识并恰好召回一次；由 CLI 或模型请求 worker 调用。"
  def context(cid, query) do
    with {:ok, snapshot, recalled} <- recollect(cid, query, & &1) do
      context = %{
        mind: Appraisal.mind(snapshot.mind),
        mental_models: snapshot.cache["models"],
        model_metadata: snapshot.cache["metadata"],
        model_cached_at_ms: snapshot.cache["at_ms"],
        memories: recalled.results,
        recall_latency_ms: recalled.latency_ms,
        memory_retrieval: :hindsight_once,
        memory_truth: "Subjective memory; not current numeric world truth."
      }

      {:ok,
       if(snapshot.mind["affect"],
         do: Map.put(context, :emotion_context, Appraisal.context(snapshot.mind)),
         else: context
       )}
    end
  end

  @doc """
  心智快照（`NpcServer.Mind`）用的只读视图，由选择位置的发问 worker 调用；读的是规则模式的状态。
  与 `context/2` 同样读缓存认识并恰好召回一次（单次请求最多等 #{@mind_recall_timeout_ms} 毫秒：选择是秒级决策），
  另给出还没写进 Hindsight 的经历原文。返回 `{:ok, 视图}`：

      feelings       此刻仍活跃的情绪 `[%{emotion:, actor:, intensity:}]`（`Life.State.feelings/2`）
      relationships  对各角色的信任 `[%{actor:, trust:}]`（`Life.State.relationships/1`）
      recent         还没写进 Hindsight 的经历原文（已封存待写的片段在前，未封存的尾部在后；各自旧在前）
      models         缓存的认识 `[{id, 正文}]`，按 `Life.Hindsight.model_ids/0` 的次序
      memories       本次召回的结果（Hindsight 的原始行，正文在 `"text"`）
      recall_ms      本次召回耗时

  读不到就是显式失败，不冒充“没有记忆”：`{:error, :life_not_running | :life_not_ready |
  {:life_models_unavailable, 原因} | 召回的失败原因}`。新 NPC 的空 bank 召回为空是正常结果。
  """
  def mind(cid, query) do
    with {:ok, snapshot, recalled} <-
           recollect(cid, query, &Map.put(&1, :timeout_ms, @mind_recall_timeout_ms)) do
      {:ok,
       %{
         feelings: State.feelings(snapshot.mind, snapshot.now_ms),
         relationships: State.relationships(snapshot.mind),
         recent: snapshot.recent,
         models:
           for(
             id <- Hindsight.model_ids(),
             text = snapshot.cache["models"][id],
             do: {id, text}
           ),
         memories: recalled.results,
         recall_ms: recalled.latency_ms
       }}
    end
  end

  # 读一次 owner 快照，再在调用者进程里恰好召回一次；召回的成败记回 owner 供 observe 查看。
  defp recollect(cid, query, configure) do
    with {:ok, snapshot} <- call(cid, :context) do
      case snapshot.adapter.recall(configure.(snapshot.config), query, snapshot.now_ms) do
        {:ok, recalled} ->
          GenServer.cast(
            name(cid),
            {:recall, Map.put(Map.drop(recalled, [:results]), :status, :done)}
          )

          {:ok, snapshot, recalled}

        {:error, reason} ->
          GenServer.cast(name(cid), {:recall, %{status: :failed, error: reason}})
          {:error, reason}
      end
    end
  end

  @doc "接收 Body 当前场景身份和纯观察；不阻塞发送者。"
  def observation(pid, observation), do: GenServer.cast(pid, {:observation, observation})
  @doc "记录社交决策及实际权威终态，并持久确认已完成的感谢来源。"
  def decision(pid, data), do: GenServer.cast(pid, {:decision, data})

  @doc "接纳 Body 实际收到的权威 Speech；只保存主观经历，不推进 World 游标或修改心智。"
  def speech(pid, message), do: GenServer.cast(pid, {:speech, message})

  @doc "接纳真实 Runtime 的动作终态，供下一次情绪评价引用（只在模型评价情绪时使用；规则模式不建这条流水）。"
  def experience(pid, outcome), do: GenServer.cast(pid, {:experience, outcome})

  @doc """
  接纳一项已结束的活动（做了什么、结果如何，一句英文）作为主观经历：与 World 事件、Speech 同样进未封存的尾部，
  攒够一个片段后写入 Hindsight。由统一形态的 Runtime 在活动结束时调用一次；不改 World 游标、情绪或关系。
  """
  def activity(pid, text), do: GenServer.cast(pid, {:activity, text})

  @doc "提交本次模型情绪评价；持久化完成才返回成功，调用方随后才执行动作。"
  def appraise(cid, through, entries), do: call(cid, {:appraise, through, entries})

  defp name(cid), do: {:global, {__MODULE__, node(), cid}}

  defp call(cid, request) do
    try do
      GenServer.call(name(cid), request)
    catch
      :exit, {:noproc, _} -> {:error, :life_not_running}
      :exit, _ -> {:error, :life_unavailable}
    end
  end

  @impl true
  def init({owner, context, profile}) do
    Process.flag(:trap_exit, true)
    options = profile.life

    config =
      Map.merge(options, %{
        bank: "npc-life-#{context.cid}",
        url: Map.get(options, :url) || System.fetch_env!("NPC_LIFE_HINDSIGHT_URL")
      })

    send(self(), :poll)

    {:ok,
     %{
       owner: owner,
       context: context,
       memory: Map.get(profile, :memory, DataService.NpcMemory),
       adapter: Map.get(options, :hindsight, Hindsight),
       config: config,
       now: Map.get(options, :clock, fn -> System.system_time(:millisecond) end),
       poll_ms: Map.get(options, :poll_ms, 1000),
       row: nil,
       poll: nil,
       job: nil,
       error: nil,
       observation: nil,
       appraise: Map.get(options, :appraise, false),
       experience_pending: [],
       decision: nil,
       recall: nil,
       status: nil,
       job_error: nil,
       speech_pending: []
     }}
  end

  @impl true
  def handle_call(:observe, _, s) do
    row = s.row
    cache = row && row["cache"]

    {:reply,
     {:ok,
      %{
        cid: s.context.cid,
        bank: s.config.bank,
        state: row && row["state"],
        mind: row && State.view(row["state"], s.now.()),
        pending_episodes: if(row, do: length(row["pending"]), else: 0),
        pending_fragments: if(row, do: length(row["fragments"]), else: 0),
        retained: if(row, do: row["retained"], else: 0),
        cache: cache,
        thanked_seq: row && row["thanked_seq"],
        cache_age_ms: if(cache && cache["at_ms"], do: max(0, s.now.() - cache["at_ms"])),
        cache_dirty: row && row["dirty"],
        refresh_at_ms: row && row["refresh_at_ms"],
        job: s.job && s.job.kind,
        error: s.error || s.job_error,
        hindsight: s.status,
        recall: s.recall,
        decision: s.decision,
        unsaved_speech: length(s.speech_pending),
        unsaved_experiences: length(s.experience_pending),
        emotion_owner: if(s.appraise, do: :model, else: :construction_rules)
      }}, s}
  end

  def handle_call(:context, _, %{row: nil} = s), do: {:reply, {:error, :life_not_ready}, s}

  def handle_call(:context, _, s) do
    if s.row["cache"] do
      {:reply,
       {:ok,
        %{
          adapter: s.adapter,
          config: s.config,
          now_ms: s.now.(),
          mind: State.view(s.row["state"], s.now.()),
          cache: s.row["cache"],
          # 还没写进 Hindsight 的经历：已封存待写的片段，加未封存的尾部。
          recent: Enum.map(s.row["fragments"] ++ s.row["pending"], & &1["text"])
        }}, s}
    else
      {:reply, {:error, {:life_models_unavailable, s.job_error || s.error}}, s}
    end
  end

  def handle_call(kind, _, %{row: nil} = s) when kind in [:flush, :refresh],
    do: {:reply, {:error, :life_not_ready}, s}

  def handle_call(kind, _, %{job: job} = s) when kind in [:flush, :refresh] and job != nil,
    do: {:reply, {:ok, %{status: :busy, job: job.kind}}, s}

  def handle_call(:flush, _, s) do
    case save(s, seal(s.row, true)) do
      {:ok, s} ->
        if s.row["fragments"] == [],
          do: {:reply, {:ok, %{status: :empty}}, s},
          else: {:reply, {:ok, %{status: :started}}, start_job(s, :retain)}

      {:error, s} ->
        {:reply, {:error, s.error}, s}
    end
  end

  def handle_call(:refresh, _, s),
    do: {:reply, {:ok, %{status: :started}}, start_job(s, :refresh)}

  def handle_call({:appraise, _, _}, _, %{row: nil} = s),
    do: {:reply, {:error, :life_not_ready}, s}

  def handle_call({:appraise, through, entries}, _, s) do
    case Appraisal.apply(s.row["state"], through, entries, s.now.()) do
      {:ok, canonical} ->
        case save(s, %{s.row | "state" => canonical}) do
          {:ok, s} ->
            publish(s)

            Logger.info(
              "npc_emotion_appraised cid=#{s.context.cid} through=#{through} count=#{length(entries)}"
            )

            {:reply, :ok, s}

          {:error, s} ->
            {:reply, {:error, s.error}, s}
        end

      {:error, reason} ->
        Logger.warning("npc_emotion_rejected cid=#{s.context.cid} reason=#{reason}")
        {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_cast({:observation, o}, s) do
    context = %{s.context | scene_id: Map.get(o.self, :scene_id, s.context.scene_id)}
    s = %{s | observation: o, context: context}

    s =
      if s.appraise and s.row != nil and s.row["state"]["affect"]["next_seq"] == 0 and
           not Enum.any?(s.experience_pending, fn {kind, _, _, _} -> kind == "situation" end) do
        enqueue_experience(s, "situation", %{self: o.self, entities: o.entities})
      else
        s
      end

    {:noreply, s}
  end

  def handle_cast({:experience, outcome}, s) do
    position = s.observation && s.observation.self.position
    [projected] = NpcServer.Perception.project(outcome, [], position)
    {:noreply, enqueue_experience(s, "outcome", projected)}
  end

  def handle_cast({:decision, data}, s) do
    s = %{s | decision: data}

    if s.row != nil and Map.get(data, :thanks, 0) > s.row["thanked_seq"] do
      case save(s, Map.put(s.row, "thanked_seq", data.thanks)) do
        {:ok, s} ->
          publish(s)
          {:noreply, s}

        {:error, s} ->
          {:noreply, s}
      end
    else
      {:noreply, s}
    end
  end

  def handle_cast({:recall, data}, s), do: {:noreply, %{s | recall: data}}

  # 活动只能在一次成功的选择之后结束，而选择要先读到本 owner 的视图，所以此时 row 必已加载。
  def handle_cast({:activity, text}, s) do
    at_ms = s.now.()
    at_utc = at_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    episode = %{
      "id" => "activity:#{at_ms}",
      "at_ms" => at_ms,
      "text" => "At #{at_utc} (UTC), " <> text
    }

    case save(s, seal(Map.update!(s.row, "pending", &(&1 ++ [episode])), false)) do
      {:ok, s} -> {:noreply, automatic(s)}
      {:error, s} -> {:noreply, s}
    end
  end

  def handle_cast({:speech, message}, s) do
    s = %{s | speech_pending: s.speech_pending ++ [message]}
    {:noreply, save_speech(s)}
  end

  @impl true
  def handle_info(:poll, %{poll: nil} = s) do
    memory = s.memory
    context = s.context
    row = s.row

    {:noreply,
     worker(s, :poll, fn ->
       with {:ok, loaded} <- if(row, do: {:ok, row}, else: Memory.life_load(memory, context.cid)),
            {:ok, route} <- context.router.route(context.scene_id),
            {:ok, events} <-
              VoxelRegion.World.interactions_since(
                route.world_ref,
                loaded && loaded["state"]["cursor"]
              ) do
         {:ok, %{row: loaded, events: Map.update!(events, :events, &buildings(route.world_ref, &1))}}
       end
     end)}
  end

  def handle_info(:poll, s), do: {:noreply, s}

  def handle_info({:result, :poll, result}, s) do
    s = done(s, :poll)

    s =
      case result do
        {:ok, %{row: loaded, events: events}} ->
          accept_world(s, loaded, events)

        {:error, reason} ->
          error(s, reason)
      end

    Process.send_after(self(), :poll, s.poll_ms)
    {:noreply, s}
  end

  def handle_info({:result, :job, result}, s) do
    job = s.job
    s = done(s, :job)

    s =
      case result do
        {:ok, result} ->
          row =
            case job.kind do
              :retain ->
                %{
                  s.row
                  | "fragments" => Enum.reject(s.row["fragments"], &(&1["id"] in job.ids)),
                    "retained" => s.row["retained"] + length(job.ids),
                    "dirty" => true
                }

              _ ->
                %{
                  s.row
                  | "cache" => json(Map.put(result.models, :at_ms, s.now.())),
                    "dirty" => if(job.kind == :refresh, do: false, else: s.row["dirty"]),
                    "refresh_at_ms" =>
                      if(job.kind == :refresh, do: s.now.(), else: s.row["refresh_at_ms"])
                }
            end

          case save(s, row) do
            {:ok, s} -> automatic(%{s | status: result.status, job_error: nil})
            {:error, s} -> s
          end

        {:error, reason} ->
          job_error(s, reason)
      end

    {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, s) do
    slot =
      cond do
        s.poll && s.poll.ref == ref -> :poll
        s.job && s.job.ref == ref -> :job
        true -> nil
      end

    if slot do
      s = done(s, slot)

      s =
        if slot == :poll,
          do: error(s, {:life_worker_failed, exit_kind(reason)}),
          else: job_error(s, {:life_worker_failed, exit_kind(reason)})

      if slot == :poll, do: Process.send_after(self(), :poll, s.poll_ms)
      {:noreply, s}
    else
      {:noreply, s}
    end
  end

  def handle_info({:EXIT, owner, _}, %{owner: owner} = s) do
    for w <- [s.poll, s.job], w != nil, do: Process.exit(w.pid, :shutdown)
    {:stop, :shutdown, s}
  end

  def handle_info({:EXIT, _, _}, s), do: {:noreply, s}

  # 事件里 `prefab` 是所属建筑的定义 id（散格与 2026-11-12 之前提交的事件没有）；名字的 owner 是 World 的发布元信息，
  # 这里读一次写进事件的 `building`。空名发布与作者目录里没发布过的定义没有名字。本批没有涉及建筑的事件就不读。
  defp buildings(world, events) do
    if Enum.any?(events, & &1[:prefab]) do
      names =
        for %{id: id, name: name} <- VoxelRegion.World.published_prefab_metadata(world),
            name != "",
            into: %{},
            do: {id, name}

      Enum.map(events, &Map.put(&1, :building, names[&1[:prefab]]))
    else
      events
    end
  end

  defp initial(cid, events, now),
    do: %{
      "state" => State.new(cid, events.world_id, events.cursor, now),
      "pending" => [],
      "fragments" => [],
      "cache" => nil,
      "retained" => 0,
      "dirty" => false,
      "refresh_at_ms" => nil,
      "thanked_seq" => 0
    }

  # 只有 owner 推进当前 canonical；在途 World 读取不能覆盖模型刚提交的情绪。
  defp accept_world(s, loaded, events) do
    row = s.row || loaded || initial(s.context.cid, events, s.now.())

    if row["state"]["world_id"] != events.world_id do
      error(s, :life_world_identity_mismatch)
    else
      canonical = State.upgrade(row["state"])

      canonical =
        cond do
          s.appraise -> Appraisal.enable(canonical)
          Map.has_key?(canonical, "affect") -> {:error, :emotion_owner_mismatch}
          true -> canonical
        end

      case canonical do
        {:error, reason} -> error(s, reason)
        canonical -> advance_world(s, row, canonical, events)
      end
    end
  end

  defp advance_world(s, row, canonical, events) do
    {canonical, episodes} =
      State.advance(
        canonical,
        events.events,
        events.cursor,
        s.now.(),
        if(s.appraise, do: :model, else: :rules)
      )

    canonical =
      if s.appraise do
        Enum.reduce(episodes, canonical, fn episode, state ->
          Appraisal.enqueue(
            state,
            "world",
            episode,
            [episode["actor"] | targets(s)],
            episode["at_ms"]
          )
        end)
      else
        canonical
      end

    candidate = %{row | "state" => canonical, "pending" => row["pending"] ++ episodes}

    case save(s, seal(candidate, false)) do
      {:ok, s} ->
        s = s |> save_experiences() |> save_speech()
        publish(s)
        automatic(s)

      {:error, s} ->
        s
    end
  end

  defp targets(%{observation: nil, context: context}), do: [context.cid]

  defp targets(s),
    do: Enum.uniq([s.context.cid | Enum.map(s.observation.entities, & &1.entity_id)])

  defp enqueue_experience(%{appraise: false} = s, _, _), do: s

  defp enqueue_experience(s, kind, data) do
    source = {kind, json(NpcServer.Context.plain(data)), targets(s), s.now.()}
    save_experiences(%{s | experience_pending: s.experience_pending ++ [source]})
  end

  defp save_experiences(%{row: nil} = s), do: s
  defp save_experiences(%{experience_pending: []} = s), do: s

  defp save_experiences(s) do
    canonical =
      Enum.reduce(s.experience_pending, s.row["state"], fn {kind, data, ids, at}, state ->
        Appraisal.enqueue(state, kind, data, ids, at)
      end)

    case save(s, %{s.row | "state" => canonical}) do
      {:ok, s} ->
        publish(s)
        %{s | experience_pending: []}

      {:error, s} ->
        s
    end
  end

  # 首次 World 身份尚未加载或写入失败时保留未落盘输入；既有轮询继续尝试，观察显式报告 unsaved_speech/error。
  defp save_speech(%{row: nil} = s), do: s
  defp save_speech(%{speech_pending: []} = s), do: s

  defp save_speech(s) do
    # Scene 已保证一次权威投递；存储失败不提交 row，不清空输入，原 outbox 重试无需第二套去重状态。
    episodes = Enum.map(s.speech_pending, &Dialogue.episode(&1, s.context.cid))
    row = Map.update!(s.row, "pending", &(&1 ++ episodes))

    canonical =
      if s.appraise do
        Enum.reduce(s.speech_pending, row["state"], fn message, state ->
          Appraisal.enqueue(
            state,
            "speech",
            json(message),
            Enum.uniq([message.speaker_id | targets(s)]),
            message.at_ms
          )
        end)
      else
        row["state"]
      end

    row = %{row | "state" => canonical}

    case save(s, seal(row, false)) do
      {:ok, s} ->
        publish(s)
        automatic(%{s | speech_pending: []})

      {:error, s} ->
        s
    end
  end

  defp seal(row, force) do
    {fragments, tail} = fragments(row["pending"], force, [])
    %{row | "pending" => tail, "fragments" => row["fragments"] ++ fragments}
  end

  defp fragments([], _, acc), do: {Enum.reverse(acc), []}

  defp fragments(episodes, force, acc) do
    {chunk, rest} = take_fragment(episodes, [], 0)

    if force or Enum.sum(Enum.map(chunk, &String.length(&1["text"]))) >= @fragment_chars do
      first = hd(chunk)
      last = List.last(chunk)
      id = first["id"] <> ":fragment:" <> last["id"]

      fragment = %{
        "id" => id,
        "at_ms" => first["at_ms"],
        "text" => Enum.map_join(chunk, "\n", & &1["text"])
      }

      fragments(rest, force, [fragment | acc])
    else
      {Enum.reverse(acc), episodes}
    end
  end

  defp take_fragment([], acc, _), do: {Enum.reverse(acc), []}
  defp take_fragment(rest, acc, size) when size >= @fragment_chars, do: {Enum.reverse(acc), rest}

  defp take_fragment([e | rest], acc, size),
    do: take_fragment(rest, [e | acc], size + String.length(e["text"]))

  defp save(s, row) do
    if row == s.row do
      {:ok, %{s | error: nil}}
    else
      case Memory.life_save(s.memory, s.context.cid, row) do
        :ok -> {:ok, %{s | row: row, error: nil}}
        {:error, reason} -> {:error, error(s, reason)}
      end
    end
  end

  defp publish(s), do: send(s.owner, {:life_state, s.row["state"], s.row["thanked_seq"]})
  defp automatic(%{job: job} = s) when job != nil, do: s
  defp automatic(%{job_error: reason} = s) when reason != nil, do: s

  defp automatic(s) do
    cond do
      s.row["fragments"] != [] ->
        start_job(s, :retain)

      s.row["cache"] == nil ->
        start_job(s, :models)

      s.row["dirty"] and
          (s.row["refresh_at_ms"] == nil or s.now.() - s.row["refresh_at_ms"] >= @refresh_ms) ->
        start_job(s, :refresh)

      true ->
        s
    end
  end

  defp start_job(s, kind) do
    adapter = s.adapter
    config = s.config
    fragments = s.row["fragments"]

    s =
      worker(s, :job, fn ->
        {:ok, _} = Application.ensure_all_started(:inets)
        {:ok, _} = Application.ensure_all_started(:ssl)

        with {:ok, _} <- adapter.ensure(config, "NPC #{s.context.cid}"),
             {:ok, result} <-
               (case kind do
                  :retain -> adapter.retain(config, fragments)
                  :refresh -> adapter.refresh(config)
                  :models -> adapter.models(config)
                end),
             {:ok, status} <- adapter.status(config) do
          {:ok, %{models: result, status: Map.put(status, :last_operation, result)}}
        end
      end)

    %{
      s
      | job_error: nil,
        job: Map.merge(s.job, %{kind: kind, ids: Enum.map(fragments, & &1["id"])}),
        row: if(kind == :refresh, do: Map.put(s.row, "refresh_at_ms", s.now.()), else: s.row)
    }
  end

  defp worker(s, slot, fun) do
    owner = self()

    {pid, ref} =
      :erlang.spawn_opt(fn -> send(owner, {:result, slot, fun.()}) end, [:link, :monitor])

    Map.put(s, slot, %{pid: pid, ref: ref})
  end

  defp done(s, slot) do
    Process.demonitor(Map.fetch!(s, slot).ref, [:flush])
    Map.put(s, slot, nil)
  end

  defp error(s, reason) do
    Logger.warning("npc_life_error cid=#{s.context.cid} reason=#{inspect(reason)}")
    %{s | error: reason}
  end

  defp job_error(s, reason) do
    Logger.warning("npc_life_memory_error cid=#{s.context.cid} reason=#{inspect(reason)}")
    %{s | job_error: reason}
  end

  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_), do: :worker_failed
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
