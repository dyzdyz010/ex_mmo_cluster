defmodule GateServer.Npc.Life do
  @moduledoc """
  NPC 人生状态唯一 owner，跟随 Runtime 生命周期。canonical 心智、World 游标、待写经历与认识缓存
  原子保存在 NpcMemory 的 life/state 行；观察只派生衰减视图。World 读取与 Hindsight 使用独立 worker，
  慢记忆写入期间继续接纳权威事件。短经历先封成约 3000 字片段，失败重用原片段 id。
  CLI observe/flush/refresh/context 以永久 cid 定位本节点 owner；网络调用不会占用 Body 邮箱。
  """
  use GenServer
  require Logger
  alias GateServer.Npc.{Memory, Life.State, Life.Hindsight}
  @fragment_chars 3000
  @refresh_ms 600_000

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
    with {:ok, snapshot} <- call(cid, :context) do
      case snapshot.adapter.recall(snapshot.config, query, snapshot.now_ms) do
        {:ok, recalled} ->
          GenServer.cast(
            name(cid),
            {:recall, Map.put(Map.drop(recalled, [:results]), :status, :done)}
          )

          {:ok,
           %{
             mind: snapshot.mind,
             mental_models: snapshot.cache["models"],
             model_metadata: snapshot.cache["metadata"],
             model_cached_at_ms: snapshot.cache["at_ms"],
             memories: recalled.results,
             recall_latency_ms: recalled.latency_ms,
             memory_retrieval: :hindsight_once,
             memory_truth: "Subjective memory; not current numeric world truth."
           }}

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
       decision: nil,
       recall: nil,
       status: nil,
       job_error: nil
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
        decision: s.decision
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
          cache: s.row["cache"]
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

  @impl true
  def handle_cast({:observation, o}, s) do
    context = %{s.context | scene_id: Map.get(o.self, :scene_id, s.context.scene_id)}
    {:noreply, %{s | observation: o, context: context}}
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

  @impl true
  def handle_info(:poll, %{poll: nil} = s) do
    memory = s.memory
    context = s.context
    row = s.row
    now = s.now.()

    {:noreply,
     worker(s, :poll, fn ->
       with {:ok, loaded} <- if(row, do: {:ok, row}, else: Memory.life_load(memory, context.cid)),
            {:ok, route} <- context.router.route(context.scene_id),
            {:ok, events} <-
              VoxelRegion.World.interactions_since(
                route.world_ref,
                loaded && loaded["state"]["cursor"]
              ) do
         case loaded do
           nil ->
             {:ok, initial(context.cid, events, now)}

           %{"state" => %{"world_id" => world}} when world == events.world_id ->
             canonical = if row, do: loaded["state"], else: State.upgrade(loaded["state"])

             if canonical != loaded["state"],
               do: Logger.info("npc_life_state_upgraded cid=#{context.cid} added=sociability")

             {canonical, episodes} =
               State.advance(canonical, events.events, events.cursor, now)

             {:ok, %{loaded | "state" => canonical, "pending" => loaded["pending"] ++ episodes}}

           _ ->
             {:error, :life_world_identity_mismatch}
         end
       end
     end)}
  end

  def handle_info(:poll, s), do: {:noreply, s}

  def handle_info({:result, :poll, result}, s) do
    s = done(s, :poll)

    s =
      case result do
        {:ok, candidate} ->
          # 慢轮询期间批写完成可能更新 outbox；轮询只接纳其新游标与尾经历。
          candidate =
            if s.row,
              do: %{
                s.row
                | "state" => candidate["state"],
                  "pending" =>
                    s.row["pending"] ++
                      Enum.filter(candidate["pending"], &(&1["seq"] > s.row["state"]["cursor"]))
              },
              else: candidate

          case save(s, seal(candidate, false)) do
            {:ok, s} ->
              publish(s)
              automatic(s)

            {:error, s} ->
              s
          end

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
      id = first["id"] <> ":fragment:" <> to_string(first["seq"]) <> "-" <> to_string(last["seq"])

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
