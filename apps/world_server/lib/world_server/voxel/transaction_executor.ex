defmodule WorldServer.Voxel.TransactionExecutor do
  @moduledoc """
  Async driver that runs a `BuildTransaction` through Scene participants.

  The coordinator owns the world-side state machine; this module turns a
  `begin_transaction` into the actual prepare/commit/abort calls against each
  participant's Scene-side adapter, and posts ACKs and the final decision back
  to the coordinator.

  Phase summary:

  1. Call the scene caller's `prepare/4` for every participant in parallel.
     Each call has a per-participant timeout (`:per_participant_timeout_ms`,
     default 5_000) and the whole executor pass has an overall transaction
     timeout (`:transaction_timeout_ms`, default 30_000) starting from the
     beginning of `execute/4`.
  2. Post a `prepare_ack` to the coordinator for each participant (`:prepared`
     when prepare succeeded, `:failed` otherwise — including timeout, exit, and
     `{:error, _}` returns).
  3. Read the resulting transaction state from the coordinator. If it reached
     `:prepared`, **record the commit decision first** (coordinator → `:committing`,
     **已决不可逆**), then dispatch `commit/3` on every Scene participant (also in
     parallel, with `:commit_timeout_ms`). 阶段4 / world-2pc-3 **durable barrier**:
     a participant's `commit/3` returning `{:ok, _}` is its **durable-ack**
     (scene side persisted to DB, confirmed `chunk_version >= commit version`,
     deleted its fence before replying); the executor feeds each durable-ack
     back to the coordinator via `commit_durable_ack/3`. The transaction only
     reaches `:committed` once **every** participant durable-acks. commit
     failures are **never** turned into an abort (契约#2): they leave the
     transaction in `:committing` to be re-dispatched by a driver/reaper.
     Otherwise (the coordinator moved to `:aborting` because of a failure ack,
     or any other unexpected state), dispatch `abort/3` on the participants that
     did manage to prepare (with `:abort_timeout_ms`) and record the
     coordinator's abort decision.

  Result shape adds `committed?: boolean()` — `true` only when every participant
  durable-acked this pass (`:committed`); `false` when the transaction is still
  `:committing` (some participant commit failed and must be re-dispatched) or on
  abort.

  Failure modes that map to `:failed` ack with a structured reason:

  - `{:error, reason}` returned from the scene caller → reason kept as-is.
  - Per-participant timeout → reason `:timeout`.
  - Task crash / exit → reason `{:participant_crashed, exit_reason}`.
  - Overall transaction timeout cancels in-flight tasks; pending participants
    are reported with reason `:transaction_timeout` and the executor proceeds
    to the abort decision.

  Replay short-circuit: when the transaction is already `:committed` or
  `:aborted`, no scene caller side-effects are triggered.

  This version still does not start a long-running watcher process. The overall
  timeout uses the running task stream's deadline; once the executor returns,
  the durable state in the coordinator (plus the structured ack reasons logged
  through `CliObserve`) is the source of truth.
  """

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator

  @default_scene_caller SceneServer.Voxel.BuildTransactionApplier

  @default_per_participant_timeout_ms 5_000
  @default_transaction_timeout_ms 30_000

  @doc """
  Drives a previously begun transaction through prepare and the coordinator
  decision, then dispatches commit or abort on the Scene participants.

  - `coordinator` — coordinator GenServer reference. Same value passed to
    `TransactionCoordinator.begin_transaction/2`.
  - `transaction` — the `BuildTransaction` returned from
    `TransactionCoordinator.begin_transaction/2`.
  - `intents_by_participant` — `%{ participant_key => intents_by_chunk }`
    where `intents_by_chunk` is `%{chunk_coord => intent_attrs}`. Each
    `intent_attrs` is the `apply_intent` payload (`:lease`, `:operation`,
    `:macro`, `:block`, …) the chunk's prepare/commit will use.

  Optional `opts`:

  - `:scene_caller` — module exposing `prepare/4`, `commit/3`, `abort/3` with
    the same signature as `SceneServer.Voxel.BuildTransactionApplier`. Defaults
    to that module.
  - `:scene_opts_by_participant` — **required** map `%{ participant_key =>
    keyword_list }` carrying the per-participant scene opts (most importantly
    `:chunk_directory` for the participant's scene_node). The executor automatically merges
    in the transaction's `:logical_scene_id` per participant. Single-region
    callers pass a one-entry map.
  - `:now_ms_fun` — 0-arity function returning a monotonic-ish timestamp; used
    in the prepare ACK timestamps. Defaults to `System.system_time/1`.
  - `:per_participant_timeout_ms` — per-participant prepare timeout in ms.
    Defaults to `5_000`. Used as the default for commit / abort dispatch when
    those phase-specific options are not supplied.
  - `:transaction_timeout_ms` — overall executor pass timeout from begin to
    decision in ms. Defaults to `30_000`. Pending participants when this
    deadline elapses are treated as `:failed` with reason
    `:transaction_timeout`, and the executor proceeds to the abort decision.
  - `:commit_timeout_ms` — per-participant commit timeout. Defaults to
    `:per_participant_timeout_ms`.
  - `:abort_timeout_ms` — per-participant abort timeout. Defaults to
    `:per_participant_timeout_ms`.
  """
  def execute(coordinator, %BuildTransaction{} = transaction, intents_by_participant, opts \\ [])
      when is_map(intents_by_participant) and is_list(opts) do
    scene_caller = Keyword.get(opts, :scene_caller, @default_scene_caller)
    now_fun = Keyword.get(opts, :now_ms_fun, &default_now_ms/0)

    per_participant_timeout =
      Keyword.get(opts, :per_participant_timeout_ms, @default_per_participant_timeout_ms)

    transaction_timeout =
      Keyword.get(opts, :transaction_timeout_ms, @default_transaction_timeout_ms)

    commit_timeout = Keyword.get(opts, :commit_timeout_ms, per_participant_timeout)
    abort_timeout = Keyword.get(opts, :abort_timeout_ms, per_participant_timeout)

    scene_opts_by_participant =
      validate_scene_opts_by_participant!(
        Keyword.get(opts, :scene_opts_by_participant),
        transaction
      )

    deadline = monotonic_now_ms() + transaction_timeout

    case transaction.state do
      already_decided when already_decided in [:committed, :aborted] ->
        emit("voxel_transaction_executor_replay_skipped", transaction, %{
          decision: already_decided
        })

        {:ok,
         %{
           transaction: transaction,
           decision: replay_decision(already_decided),
           committed?: already_decided == :committed,
           participant_results: [],
           prepare_results: []
         }}

      :prepared ->
        # Phase 3-bis fast-path: the coordinator is already past prepare —
        # this is a recovery resume, not a fresh transaction. Skip prepare /
        # record_prepare_acks entirely and dispatch commit directly. The
        # `intents_by_participant` argument is accepted for API symmetry but
        # commit phase does not consume per-chunk intents (the fence on each
        # ChunkProcess already holds them).
        emit("voxel_transaction_executor_resume_started", transaction, %{
          participant_count: length(transaction.participants),
          commit_timeout_ms: commit_timeout
        })

        prepare_results = derive_prepare_results_from_prepared_state(transaction)

        run_commit(
          coordinator,
          transaction,
          prepare_results,
          scene_caller,
          scene_opts_by_participant,
          commit_timeout,
          deadline
        )

      :committing ->
        # 阶段4 / world-2pc-3 :committing fast-path:commit decision 已记录
        # (**已决,不可逆**)但还没全 durable-ack。这是 driver/reaper 崩溃续推
        # 的典型场景。只对 commit_acks 仍 :pending 的 participant **重投递**
        # commit,绝不 abort 已决事务(契约#2)。
        emit("voxel_transaction_executor_committing_resume", transaction, %{
          pending_acks: count_pending_acks(transaction)
        })

        prepare_results = derive_prepare_results_from_committing_state(transaction)

        run_commit(
          coordinator,
          transaction,
          prepare_results,
          scene_caller,
          scene_opts_by_participant,
          commit_timeout,
          deadline
        )

      _ ->
        emit("voxel_transaction_executor_started", transaction, %{
          participant_count: length(transaction.participants),
          per_participant_timeout_ms: per_participant_timeout,
          transaction_timeout_ms: transaction_timeout
        })

        prepare_results =
          run_prepare(
            transaction,
            intents_by_participant,
            scene_caller,
            scene_opts_by_participant,
            per_participant_timeout,
            deadline
          )

        record_prepare_acks(coordinator, transaction, prepare_results, now_fun)

        transaction = fetch_transaction!(coordinator, transaction.transaction_id)

        case transaction.state do
          :prepared ->
            run_commit(
              coordinator,
              transaction,
              prepare_results,
              scene_caller,
              scene_opts_by_participant,
              commit_timeout,
              deadline
            )

          _other ->
            run_abort(
              coordinator,
              transaction,
              prepare_results,
              scene_caller,
              scene_opts_by_participant,
              abort_timeout,
              deadline
            )
        end
    end
  end

  # Phase 3-bis: synthesize a `prepare_results` list from a coordinator
  # transaction that is already in `:prepared` state. Every participant whose
  # `prepare_status` is `:prepared` becomes a runnable commit target;
  # `:failed` participants are pre-baked as errors so `run_commit` can split
  # them off without dispatching scene-side calls. The `resumed?: true`
  # marker lets observers distinguish a Phase 3-bis resume from a fresh
  # prepare ack.
  defp derive_prepare_results_from_prepared_state(transaction) do
    Enum.map(transaction.participants, fn participant ->
      case participant.prepare_status do
        :prepared -> {participant, {:ok, %{resumed?: true}}}
        :failed -> {participant, {:error, :prepare_failed_before_resume}}
        :pending -> {participant, {:error, :prepare_status_pending_at_resume}}
      end
    end)
  end

  # 阶段4 / world-2pc-3:`:committing` resume 的 prepare_results。已经 durable-ack
  # 的 participant 不再 dispatch commit(prebaked 成 `{:ok, %{already_durable?:
  # true}}`),只对仍 :pending 的 participant 重投递 commit。这让重投递只打到
  # 还没 durable 的 participant,避免对已落库的 chunk 重复 commit。
  defp derive_prepare_results_from_committing_state(transaction) do
    Enum.map(transaction.participants, fn participant ->
      case Map.get(transaction.commit_acks, participant_key(participant), :pending) do
        :durable -> {participant, {:already_durable, %{}}}
        :pending -> {participant, {:ok, %{resumed?: true}}}
      end
    end)
  end

  defp count_pending_acks(%{commit_acks: acks}) do
    Enum.count(acks, fn {_key, status} -> status == :pending end)
  end

  defp replay_decision(:committed), do: :commit
  defp replay_decision(:aborted), do: :abort

  defp run_prepare(
         transaction,
         intents_by_participant,
         scene_caller,
         scene_opts_by_participant,
         per_participant_timeout,
         deadline
       ) do
    participants = transaction.participants

    work_items =
      Enum.map(participants, fn participant ->
        key = participant_key(participant)
        intents_by_chunk = Map.get(intents_by_participant, key, %{})
        scene_opts = Map.fetch!(scene_opts_by_participant, key)
        {participant, intents_by_chunk, scene_opts}
      end)

    fun = fn {participant, intents_by_chunk, scene_opts} ->
      safely_invoke(fn ->
        apply(scene_caller, :prepare, [
          participant,
          transaction.transaction_id,
          intents_by_chunk,
          scene_opts_with_logical_scene_id(scene_opts, transaction)
        ])
      end)
    end

    work_items
    |> stream_with_deadline(fun, per_participant_timeout, deadline)
    |> Enum.zip(participants)
    |> Enum.map(fn {stream_outcome, participant} ->
      {participant, normalize_prepare_outcome(stream_outcome)}
    end)
  end

  defp normalize_prepare_outcome({:ok, {:scene_result, {:ok, summary}}}), do: {:ok, summary}
  defp normalize_prepare_outcome({:ok, {:scene_result, {:error, reason}}}), do: {:error, reason}

  defp normalize_prepare_outcome({:ok, {:scene_result, other}}) do
    # Defensive: scene caller returned something that is neither {:ok, _} nor
    # {:error, _}. Treat as failure and surface the unexpected shape.
    {:error, {:invalid_prepare_result, other}}
  end

  defp normalize_prepare_outcome({:ok, {:scene_crash, reason}}) do
    {:error, {:participant_crashed, reason}}
  end

  # Per-item timeout from Task.async_stream surfaces as {:exit, :timeout}.
  defp normalize_prepare_outcome({:exit, :timeout}), do: {:error, :timeout}
  defp normalize_prepare_outcome({:exit, reason}), do: {:error, {:participant_crashed, reason}}
  defp normalize_prepare_outcome(:transaction_timeout), do: {:error, :transaction_timeout}

  defp record_prepare_acks(coordinator, transaction, prepare_results, now_fun) do
    Enum.each(prepare_results, fn {participant, result} ->
      status =
        case result do
          {:ok, _summary} -> :prepared
          {:error, _reason} -> :failed
        end

      ack = %{
        participant_key: participant_key(participant),
        region_id: participant.region_id,
        lease_id: participant.lease_id,
        status: status,
        acked_at_ms: now_fun.()
      }

      ack =
        case result do
          {:error, reason} -> Map.put(ack, :reason, reason)
          _ -> ack
        end

      TransactionCoordinator.prepare_ack(coordinator, transaction.transaction_id, ack)
    end)
  end

  defp run_commit(
         coordinator,
         transaction,
         prepare_results,
         scene_caller,
         scene_opts_by_participant,
         commit_timeout,
         deadline
       ) do
    # 阶段4 / world-2pc-3:**先记 commit decision**(→ :committing,**已决不可
    # 逆**),再 dispatch commit。decision 先落让 driver 崩在 dispatch 中途时,
    # 重启能走 :committing fast-path 续推,而不会被误判成可 abort。
    {:ok, committing} =
      TransactionCoordinator.commit_decision(
        coordinator,
        transaction.transaction_id,
        transaction.decision_version
      )

    # to_run:本轮要 dispatch commit 的 participant(prepare ok 且尚未 durable);
    # prebaked:不 dispatch 的(prepare 前置失败 / :committing resume 里已 durable)。
    {to_run, prebaked} =
      Enum.split_with(prepare_results, fn
        {_participant, {:ok, _summary}} -> true
        _ -> false
      end)

    fun = fn {participant, _prepare_result} ->
      scene_opts = Map.fetch!(scene_opts_by_participant, participant_key(participant))

      safely_invoke(fn ->
        apply(scene_caller, :commit, [
          participant,
          committing.transaction_id,
          scene_opts_with_logical_scene_id(scene_opts, committing)
        ])
      end)
    end

    runnable_participants = Enum.map(to_run, fn {participant, _} -> participant end)

    commit_results =
      to_run
      |> stream_with_deadline(fun, commit_timeout, deadline)
      |> Enum.zip(runnable_participants)
      |> Enum.map(fn {stream_outcome, participant} ->
        {participant, normalize_dispatch_outcome(stream_outcome)}
      end)

    # 阶段4 / world-2pc-3 durable barrier:participant 的 `commit/3` 返回
    # `{:ok, _}` **就是** durable-ack(对齐契约#3:scene 侧已 persist + 确认
    # chunk_version >= commit version + 删 fence 后才回 {:ok})。逐个回报给
    # coordinator,全 durable 时 coordinator 自己把事务推到 :committed。
    # commit 失败的 participant **不** ack、**不** abort,留待重投递(契约#2)。
    #
    # 捕获每次 durable-ack 回的事务视图:完成那次返回 :committed struct(此后
    # 事务已被裁出活跃集,snapshot 查不到),所以用这个返回值判终态,而不是再
    # 去 snapshot fetch。`{:ok, :committed}` 原子(事务已被并发归档)也视为已
    # committed。
    {final_transaction, committed_via_atom?} =
      Enum.reduce(commit_results, {committing, false}, fn
        # 阶段4 / world-2pc-3 契约#3:**只有 `{:ok, %{durable?: true}}` 才是
        # durable-ack**。participant 的 commit/3 必须 persist 落库 + 确认
        # `chunk_version >= commit version` + 删 fence 后才回 durable?: true;此时
        # 才喂 commit_durable_ack 推进 durable barrier。
        {participant, {:ok, %{durable?: true}}}, {acc, committed?} ->
          case TransactionCoordinator.commit_durable_ack(
                 coordinator,
                 committing.transaction_id,
                 participant_key(participant)
               ) do
            {:ok, %BuildTransaction{} = view} -> {view, committed?}
            {:ok, :committed} -> {acc, true}
            _other -> {acc, committed?}
          end

        # `{:ok, %{durable?: false}}`:scene 已收到 commit 但**尚未 durable**(persist
        # 在途 / DB 落后)。**不**喂 ack(丢 durable barrier 会误把事务标 :committed
        # → 可能丢写),留待 driver/reaper 重投递,直到 participant 回 durable?: true。
        {_participant, {:ok, %{durable?: false}}}, acc_tuple ->
          acc_tuple

        # 防御:commit/3 回了 {:ok, _} 但没带 durable? 字段(非法/旧形态)——保守
        # 当作**未** durable,不喂 ack,交给重投递。绝不把未知形态当 durable barrier。
        {_participant, {:ok, _ambiguous}}, acc_tuple ->
          acc_tuple

        {_participant, {:error, _reason}}, acc_tuple ->
          acc_tuple
      end)

    prebaked_results =
      Enum.map(prebaked, fn {participant, prepare_result} ->
        {participant, prepare_result}
      end)

    participant_results = commit_results ++ prebaked_results

    effective_state =
      if committed_via_atom?, do: :committed, else: final_transaction.state

    case effective_state do
      :committed ->
        # final_transaction 可能仍是 :committing struct(并发归档场景),把 state
        # 校正成 :committed 用于注册 / 回值;scene_objects 字段不变。
        committed_transaction = %{final_transaction | state: :committed}

        # Phase 4 (D5):事务真正 committed(全 durable)后,才注册 scene_objects。
        # 失败非阻塞(registry 可从 SceneObjectStore 重载)。
        register_scene_objects_after_commit(
          scene_caller,
          committed_transaction,
          scene_opts_by_participant
        )

        emit("voxel_transaction_executor_committed", committed_transaction, %{
          participant_count: length(participant_results)
        })

        {:ok,
         %{
           transaction: committed_transaction,
           decision: :commit,
           committed?: true,
           participant_results: participant_results,
           prepare_results: prepare_results
         }}

      _still_committing ->
        # 还有 participant 没 durable-ack:事务**已决 commit**,但尚未 committed。
        # 不 abort、不注册 scene_objects(等真正 committed)。返回 committed?: false,
        # 让 driver/reaper 后续重投递剩余 participant。
        emit("voxel_transaction_executor_commit_pending_durable", final_transaction, %{
          pending_acks: count_pending_durable_acks(final_transaction),
          participant_count: length(participant_results)
        })

        {:ok,
         %{
           transaction: final_transaction,
           decision: :commit,
           committed?: false,
           participant_results: participant_results,
           prepare_results: prepare_results
         }}
    end
  end

  defp count_pending_durable_acks(%{commit_acks: acks}) do
    Enum.count(acks, fn {_key, status} -> status == :pending end)
  end

  defp count_pending_durable_acks(_), do: 0

  # Phase A4-3:scene_objects 已经在 coordinator allocate 阶段按 D6 字典序
  # 规则带上 owner_region_id / owner_lease_id。这里按 dispatch participant
  # key 分组,每组用自己 Scene-owner participant 的 scene_opts 调一次
  # register_scene_objects。一个 Scene-owner participant 可以覆盖多个
  # lease;object 自身仍保留真实 owner_region_id / owner_lease_id。
  #
  # Phase A4-4 (D7):同时给每个 obj 附加 in-memory `:covered_chunks_by_region`
  # 字段(从 `transaction.participants.affected_chunks` 推算 chunk → participant
  # 反向 map)。Scene-side 的 `BuildTransactionApplier.register_scene_objects`
  # 把它写入 `ObjectOwnerLookup`,让 cross-region 0x6C 广播 / damage 路由
  # 不必再跑 SELECT。该字段不持久化(`SceneObjectStore` schema 不包含),
  # 仅作 commit-time inflate 用。
  defp register_scene_objects_after_commit(scene_caller, transaction, scene_opts_by_participant) do
    case Map.get(transaction, :scene_objects, []) do
      [] ->
        :ok

      scene_objects when is_list(scene_objects) ->
        if function_exported?(scene_caller, :register_scene_objects, 2) do
          chunk_to_owner = build_chunk_to_owner_map(transaction)
          chunk_to_dispatch_participant = build_chunk_to_dispatch_participant_map(transaction)

          inflated =
            Enum.map(scene_objects, fn obj ->
              Map.put(
                obj,
                :covered_chunks_by_region,
                covered_chunks_by_region_for(obj, chunk_to_owner)
              )
            end)

          inflated
          |> group_scene_objects_by_dispatch_participant(chunk_to_dispatch_participant)
          |> Enum.each(fn
            {{:ok, dispatch_key}, objects} ->
              case Map.fetch(scene_opts_by_participant, dispatch_key) do
                {:ok, opts} ->
                  safely_invoke(fn ->
                    apply(scene_caller, :register_scene_objects, [
                      objects,
                      scene_opts_with_logical_scene_id(opts, transaction)
                    ])
                  end)

                :error ->
                  emit("voxel_scene_object_register_participant_unavailable", transaction, %{
                    participant_key: inspect(dispatch_key),
                    object_count: length(objects)
                  })
              end

            {{:error, reason}, objects} ->
              emit("voxel_scene_object_register_participant_unavailable", transaction, %{
                reason: inspect(reason),
                object_count: length(objects)
              })
          end)
        end

        :ok
    end
  end

  defp group_scene_objects_by_dispatch_participant(scene_objects, chunk_to_dispatch_participant) do
    Enum.group_by(scene_objects, fn obj ->
      dispatch_participant_key_for(obj, chunk_to_dispatch_participant)
    end)
  end

  defp dispatch_participant_key_for(obj, chunk_to_dispatch_participant) do
    case Map.fetch!(obj, :covered_chunks) |> Enum.sort() do
      [] ->
        {:error, :invalid_covered_chunks}

      [first_chunk | _] ->
        case Map.fetch(chunk_to_dispatch_participant, first_chunk) do
          {:ok, participant_key} -> {:ok, participant_key}
          :error -> {:error, {:missing_dispatch_participant, first_chunk}}
        end
    end
  end

  # `%{ chunk_coord => participant_key }` reverse map from the transaction's
  # participants. This chooses the Scene-owner dispatch target used for
  # commit-time object registry writes.
  defp build_chunk_to_dispatch_participant_map(transaction) do
    transaction.participants
    |> Enum.flat_map(fn p ->
      dispatch_key = participant_key(p)

      Enum.map(p.affected_chunks, fn coord ->
        {coord, dispatch_key}
      end)
    end)
    |> Map.new()
  end

  # `%{ chunk_coord => {region_id, lease_id} }` reverse map from the
  # transaction's participants. Each participant carries the real
  # `chunk_owners` map so a Scene-owner participant can still inflate
  # per-region object ownership correctly.
  defp build_chunk_to_owner_map(transaction) do
    transaction.participants
    |> Enum.flat_map(fn p ->
      Enum.map(p.affected_chunks, fn coord ->
        {coord, Map.fetch!(p.chunk_owners, coord)}
      end)
    end)
    |> Map.new()
  end

  # Group an object's `covered_chunks` by which real lease owns each chunk.
  defp covered_chunks_by_region_for(obj, chunk_to_owner) do
    Enum.group_by(Map.fetch!(obj, :covered_chunks), fn coord ->
      Map.fetch!(chunk_to_owner, coord)
    end)
  end

  defp run_abort(
         coordinator,
         transaction,
         prepare_results,
         scene_caller,
         scene_opts_by_participant,
         abort_timeout,
         deadline
       ) do
    {to_run, prebaked} =
      Enum.split_with(prepare_results, fn
        {_participant, {:ok, _summary}} -> true
        _ -> false
      end)

    fun = fn {participant, _prepare_result} ->
      scene_opts = Map.fetch!(scene_opts_by_participant, participant_key(participant))

      safely_invoke(fn ->
        apply(scene_caller, :abort, [
          participant,
          transaction.transaction_id,
          scene_opts_with_logical_scene_id(scene_opts, transaction)
        ])
      end)
    end

    runnable_participants = Enum.map(to_run, fn {participant, _} -> participant end)

    abort_results =
      to_run
      |> stream_with_deadline(fun, abort_timeout, deadline)
      |> Enum.zip(runnable_participants)
      |> Enum.map(fn {stream_outcome, participant} ->
        {participant, normalize_dispatch_outcome(stream_outcome)}
      end)

    prebaked_results =
      Enum.map(prebaked, fn {participant, _prepare_result} ->
        # Participants that did not prepare never held a fence; we ack them as
        # :ok so the caller can see a uniform participant_results list without
        # racing them through abort.
        {participant, :ok}
      end)

    participant_results = abort_results ++ prebaked_results

    {:ok, transaction} =
      TransactionCoordinator.abort_decision(
        coordinator,
        transaction.transaction_id,
        transaction.decision_version
      )

    emit("voxel_transaction_executor_aborted", transaction, %{
      participant_count: length(participant_results)
    })

    {:ok,
     %{
       transaction: transaction,
       decision: :abort,
       committed?: false,
       participant_results: participant_results,
       prepare_results: prepare_results
     }}
  end

  defp normalize_dispatch_outcome({:ok, {:scene_result, result}}), do: result

  defp normalize_dispatch_outcome({:ok, {:scene_crash, reason}}) do
    {:error, {:participant_crashed, reason}}
  end

  defp normalize_dispatch_outcome({:exit, :timeout}), do: {:error, :timeout}
  defp normalize_dispatch_outcome({:exit, reason}), do: {:error, {:participant_crashed, reason}}
  defp normalize_dispatch_outcome(:transaction_timeout), do: {:error, :transaction_timeout}

  # Phase A4-1 helpers ──────────────────────────────────────────────────

  defp participant_key(%{participant_key: participant_key}) when not is_nil(participant_key),
    do: participant_key

  defp scene_opts_with_logical_scene_id(opts, transaction) when is_list(opts) do
    Keyword.put(opts, :logical_scene_id, transaction.logical_scene_id)
  end

  defp validate_scene_opts_by_participant!(nil, _transaction) do
    raise ArgumentError,
          "TransactionExecutor.execute/4 requires :scene_opts_by_participant " <>
            "(map keyed by participant_key); legacy :scene_opts was " <>
            "removed in Phase A4-1"
  end

  defp validate_scene_opts_by_participant!(map, transaction) when is_map(map) do
    missing =
      transaction.participants
      |> Enum.map(&participant_key/1)
      |> Enum.reject(&Map.has_key?(map, &1))

    case missing do
      [] ->
        map

      _ ->
        raise ArgumentError,
              "TransactionExecutor.execute/4 missing scene_opts for " <>
                inspect(missing) <>
                " in :scene_opts_by_participant; got keys " <>
                inspect(Map.keys(map))
    end
  end

  defp validate_scene_opts_by_participant!(other, _transaction) do
    raise ArgumentError,
          "TransactionExecutor.execute/4 :scene_opts_by_participant must be a " <>
            "map keyed by participant_key; got " <> inspect(other)
  end

  # Wraps a 0-arity invocation that calls into the scene caller. Normal returns
  # surface as `{:scene_result, value}`; exceptions / throws / exits surface as
  # `{:scene_crash, reason}` so the participant is still reported as `:failed`
  # without bringing down the executor.
  defp safely_invoke(fun) when is_function(fun, 0) do
    {:scene_result, fun.()}
  rescue
    error ->
      {:scene_crash, {error, __STACKTRACE__}}
  catch
    :throw, value ->
      {:scene_crash, {:throw, value}}

    :exit, reason ->
      {:scene_crash, {:exit, reason}}
  end

  # Runs `fun` over `enumerable` using `Task.async_stream/3` while respecting
  # both a per-item timeout and an overall deadline. Items that did not finish
  # before the overall deadline are returned as `:transaction_timeout`. Per-item
  # timeouts surface as `:timeout`. Task crashes surface as `{:exit, reason}`.
  #
  # The result is the same length as `enumerable` and preserves order, so the
  # caller can zip it back against the source list.
  defp stream_with_deadline([], _fun, _per_item_timeout, _deadline), do: []

  defp stream_with_deadline(enumerable, fun, per_item_timeout, deadline) do
    items = Enum.to_list(enumerable)
    count = length(items)

    overall_remaining = max(deadline - monotonic_now_ms(), 0)

    if overall_remaining == 0 do
      List.duplicate(:transaction_timeout, count)
    else
      effective_timeout = min(per_item_timeout, overall_remaining)

      stream =
        Task.async_stream(items, fun,
          timeout: effective_timeout,
          on_timeout: :kill_task,
          ordered: true,
          max_concurrency: max(count, 1)
        )

      collect_with_deadline(stream, count, deadline)
    end
  end

  # Drains `stream` collecting up to `count` outcomes. If the overall deadline
  # passes before the stream finishes, the remaining slots are filled with
  # `:transaction_timeout`. We use `Enum.reduce_while/3` so we can pull one
  # element at a time and bail out the moment the deadline elapses; tasks that
  # are still in flight are linked to the temporary supervisor that
  # `Task.async_stream` owns, so letting the stream go out of scope tears them
  # down without leaking processes.
  defp collect_with_deadline(stream, count, deadline) do
    {acc, taken} =
      Enum.reduce_while(stream, {[], 0}, fn outcome, {acc, taken} ->
        if monotonic_now_ms() >= deadline do
          {:halt, {acc, taken}}
        else
          {:cont, {[outcome | acc], taken + 1}}
        end
      end)

    Enum.reverse(acc) ++ List.duplicate(:transaction_timeout, count - taken)
  end

  defp fetch_transaction!(coordinator, transaction_id) do
    snapshot = TransactionCoordinator.snapshot(coordinator)

    case Map.fetch(snapshot.transactions, transaction_id) do
      {:ok, transaction} ->
        transaction

      :error ->
        raise ArgumentError,
              "transaction #{inspect(transaction_id)} disappeared from coordinator snapshot"
    end
  end

  defp emit(event, %BuildTransaction{} = transaction, payload) do
    CliObserve.emit(event, fn ->
      Map.merge(
        %{
          transaction_id: transaction.transaction_id,
          logical_scene_id: transaction.logical_scene_id,
          state: transaction.state,
          decision_version: transaction.decision_version
        },
        payload
      )
    end)
  end

  defp default_now_ms, do: System.system_time(:millisecond)

  defp monotonic_now_ms, do: System.monotonic_time(:millisecond)
end
