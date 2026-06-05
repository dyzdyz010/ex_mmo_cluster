defmodule WorldServer.Voxel.TransactionCoordinator do
  @moduledoc """
  Coordinator for recoverable voxel build transactions.

  The coordinator owns the world-side transaction state machine. Scene
  processes remain participants: they execute prepare and commit/abort work,
  while this module records the durable intent, participant acknowledgements,
  and the single world decision for each `{transaction_id, decision_version}`
  pair.

  ## Durable persistence (阶段4 / world-2pc-4 增量持久化)

  Persistence is injected via the `:persist_rows_fn` (2-arity) and `:load_fn`
  (0-arity) start options. Production wiring uses
  `DataService.Voxel.TransactionCoordinatorStore.persist_rows_fn/1` /
  `load_fn/1` so coordinator state survives node restart through Postgres.

  **行级增量**:每次 state 突变后,coordinator 只把**变更的事务行**(以及被
  裁剪/归档时要删除的行 id)交给 `persist_rows_fn.(changed_rows, deleted_ids)`,
  不再每次 `term_to_binary` 全量历史单行 upsert。flush 是**异步**的
  (`:flush_dirty_rows` 自发消息 + 脏集合累积),回复调用方不等 DB。

  When neither option is supplied the coordinator runs purely in memory
  (used by isolated unit tests that do not need persistence).

  ## 活跃工作集 vs 历史 (阶段4 / world-2pc-4 状态裁剪)

  `transactions` / `begin_fingerprints` 只保留**活跃**(非终态)事务,避免四张
  map 随历史无界增长。事务到达终态(`:committed` / `:aborted`)后,从活跃 map
  移出,只在 `decision_index` 留一条**轻量归档记录**(decision + version +
  时间戳)用于幂等重放判定;`decisions` 同样只保留**活跃事务**及一段**有界**的
  终态决策窗口(`@decision_retention`),供 in-flight 重放 / driver 续推使用。
  归档记录足够回答"这笔是否已决、决了什么",replay 命中归档直接返回幂等结果,
  无需在内存常驻完整 `BuildTransaction`。

  ## Liveness 内生 (阶段4 / world-2pc-2 deadline 调度)

  coordinator 内建 deadline 调度:begin 时按 `timeout_at_ms` `send_after`,周期
  `@sweep_interval_ms` sweep 兜底。卡在 `:preparing` / `:prepared` 且过 deadline
  的事务自我推进到终态(preparing → abort;prepared → 交回 reaper/driver 续推
  commit,coordinator 只负责"该动了"的信号,实际 scene dispatch 由 driver/
  recovery_watcher 做)。这让"推进到终态"成为 coordinator 内生职责,不依赖外部
  one-shot 触发。
  """

  use GenServer

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionParticipant

  @default_timeout_ms :timer.seconds(30)
  @prepare_success_statuses [:prepared, :ok]
  @prepare_failure_statuses [:failed, :rejected, :error, :aborted]
  @abortable_states [:preparing, :prepared, :aborting]

  # 阶段4 / world-2pc-2:运行期周期 sweep 间隔(deadline 调度的兜底,主路径是
  # 每笔事务的 per-deadline send_after)。
  @sweep_interval_ms :timer.seconds(5)

  # Erlang timer 最大延迟(约 49.7 天)。timeout_at_ms 远在未来时(典型测试用
  # 2030 年时间戳)单笔 send_after 延迟会溢出 → clamp 到此上限,周期 sweep 兜底。
  @max_timer_delay_ms 4_294_967_295

  # 阶段4 / world-2pc-2:`:prepared` 过期被 flag 给 reaper 后,per-transaction
  # 定时器以这个 backoff 重排(不动 timeout_at_ms,保持 stale 让 reaper 拾起)。
  @flag_backoff_ms :timer.seconds(10)

  # 阶段4 / world-2pc-4:终态决策记录在 `decisions` map 里保留的最大条数。
  # 超出则按 decided_at_ms 最旧的裁掉(`decision_index` 仍保留轻量归档,幂等
  # 重放靠它,不靠 `decisions`)。
  @decision_retention 2_048

  @doc "Starts the in-memory transaction coordinator."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Begins a transaction from normalized participant leases.

  Required input is `:participants`; callers should also pass a stable
  `:transaction_id` and `:decision_version` when replay is expected. Replaying
  the same transaction id/version with the same participants returns the current
  transaction without resetting participant acknowledgements.
  """
  def begin_transaction(attrs) when is_map(attrs) or is_list(attrs) do
    begin_transaction(__MODULE__, attrs)
  end

  @doc """
  Begins a transaction using either default server plus transaction id or an explicit server.

  This arity is intentionally discriminated by the first argument: binary and
  integer values are treated as `transaction_id` for the module-named server,
  while all other server references are treated as the explicit coordinator
  process/name and `attrs` must already contain the transaction identity if one
  is required.
  """
  def begin_transaction(transaction_id, attrs)
      when (is_binary(transaction_id) or is_integer(transaction_id)) and
             (is_map(attrs) or is_list(attrs)) do
    begin_transaction(__MODULE__, transaction_id, attrs)
  end

  def begin_transaction(server, attrs) when is_map(attrs) or is_list(attrs) do
    GenServer.call(server, {:begin_transaction, attrs})
  end

  @doc """
  Begins a transaction against an explicit coordinator with an explicit transaction id.

  Use this server-explicit form in tests, isolated supervisors, and adapters that
  should not call the module-named coordinator. `transaction_id` is written into
  `attrs` before normalization, so replay and conflict checks use that id
  together with the normalized participants and `decision_version`.
  """
  def begin_transaction(server, transaction_id, attrs) when is_map(attrs) or is_list(attrs) do
    attrs =
      attrs
      |> attrs_map()
      |> Map.put(:transaction_id, transaction_id)

    begin_transaction(server, attrs)
  end

  @doc """
  Records a participant prepare acknowledgement.

  Acknowledgements must include `:participant_key` plus `:status`. Accepted statuses are
  `:prepared`/`:ok` for success and
  `:failed`/`:rejected`/`:error`/`:aborted` for failure.
  """
  def prepare_ack(transaction_id, ack) when is_map(ack) or is_list(ack) do
    prepare_ack(__MODULE__, transaction_id, ack)
  end

  @doc """
  Records a participant prepare acknowledgement against an explicit coordinator.

  The server-explicit form keeps the same `transaction_id` matching rules as the
  default-server form, but directs the call to the supplied GenServer. The ack is
  matched by `participant_key` so stale or unknown participants can be
  rejected without consulting Scene directly.
  """
  def prepare_ack(server, transaction_id, ack) when is_map(ack) or is_list(ack) do
    GenServer.call(server, {:prepare_ack, transaction_id, ack})
  end

  @doc """
  Records a commit decision for a prepared transaction.

  Commit is idempotent for the exact `{transaction_id, decision_version}` pair.
  A duplicate commit decision returns the existing transaction without changing
  timestamps, participant status, or the decision log.
  """
  def commit_decision(transaction_id, decision_version) do
    commit_decision(__MODULE__, transaction_id, decision_version)
  end

  @doc """
  Records a commit decision against an explicit coordinator.

  The pair `{transaction_id, decision_version}` is the idempotency key. Replaying
  the same commit for the same pair returns the existing transaction; using the
  same `transaction_id` with another decision or decision version is rejected.
  """
  def commit_decision(server, transaction_id, decision_version) do
    GenServer.call(server, {:decision, transaction_id, decision_version, :commit})
  end

  @doc """
  Records an abort decision for a preparing, prepared, or aborting transaction.

  Abort is idempotent for the exact `{transaction_id, decision_version}` pair.
  """
  def abort_decision(transaction_id, decision_version) do
    abort_decision(__MODULE__, transaction_id, decision_version)
  end

  @doc """
  Records an abort decision against an explicit coordinator.

  The server-explicit form uses the same `{transaction_id, decision_version}`
  discriminator as commits: exact abort replays are idempotent, conflicting
  decisions for the same transaction are rejected, and the supplied server owns
  the in-memory decision log.
  """
  def abort_decision(server, transaction_id, decision_version) do
    GenServer.call(server, {:decision, transaction_id, decision_version, :abort})
  end

  @doc """
  Records a participant's **durable** commit acknowledgement (契约#3).

  A `commit/3` participant must persist its chunk snapshot to the DB and confirm
  `chunk_version >= 本次 commit version` *before* returning `{:ok}`; that
  `{:ok}` is the durable signal the driver feeds back here. When **every**
  participant has durable-acked, the transaction advances from `:committing`
  to `:committed`.

  Idempotent: re-acking an already-durable participant (or acking after the
  transaction is already `:committed`) returns `{:ok, transaction}` without
  changing state. Acking a participant on a transaction that is **not** in the
  decided-commit region returns `{:error, :not_committing}` so a caller cannot
  fabricate a durable barrier on an undecided transaction.
  """
  def commit_durable_ack(transaction_id, participant_key) do
    commit_durable_ack(__MODULE__, transaction_id, participant_key)
  end

  @doc "Records a participant durable commit ack against an explicit coordinator."
  def commit_durable_ack(server, transaction_id, participant_key) do
    GenServer.call(server, {:commit_durable_ack, transaction_id, participant_key})
  end

  @doc """
  Returns the full active `BuildTransaction` for `transaction_id`, or `:error`.

  Drivers use this to fetch the authoritative coordinator state when resuming;
  it reads only the active working set (terminal transactions are archived and
  no longer carry a full struct).
  """
  def fetch_active(server \\ __MODULE__, transaction_id) do
    GenServer.call(server, {:fetch_active, transaction_id})
  end

  @doc "Returns a structured snapshot for CLI/debug inspection."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc """
  Forces a deadline sweep right now (used by the recovery reaper / tests).

  Returns the list of `{transaction_id, action}` the sweep took
  (`:advanced_to_abort` / `:flagged_for_resume` / `:noop`). The reaper consumes
  the `:flagged_for_resume` entries to actually re-dispatch commit through a
  driver; coordinator itself only owns the abort half (it has no scene caller).
  """
  def sweep_deadlines(server \\ __MODULE__) do
    GenServer.call(server, :sweep_deadlines)
  end

  @impl true
  def init(opts) do
    # 阶段4 / world-2pc-4:行级增量持久化。`:persist_rows_fn` 是 2-arity
    # `fn changed_rows, deleted_ids -> :ok | {:error, _}`;旧的全量 `:persist_fn`
    # 不再支持(无迁移债)。
    persist_rows_fn = Keyword.get(opts, :persist_rows_fn)
    load_fn = Keyword.get(opts, :load_fn)
    next_object_id_fn = Keyword.get(opts, :next_object_id_fn, &default_next_object_id/0)
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    # 测试可注入,生产用 monotonic deadline timer。
    deadline_enabled? = Keyword.get(opts, :deadline_scheduling?, true)

    base = %{
      transactions: %{},
      begin_fingerprints: %{},
      decisions: %{},
      decision_index: %{},
      persist_rows_fn: persist_rows_fn,
      next_object_id_fn: next_object_id_fn,
      sweep_interval_ms: sweep_interval_ms,
      deadline_enabled?: deadline_enabled?,
      # 阶段4 / world-2pc-4:异步增量 flush 的脏集合。`dirty_rows` 是待写的
      # transaction_id set,`deleted_rows` 是待删的 transaction_id set,
      # `flush_scheduled?` 防止 handle_continue 重复排队。
      dirty_rows: MapSet.new(),
      deleted_rows: MapSet.new(),
      flush_scheduled?: false,
      # 每笔活跃事务的 deadline timer ref,用于在到达终态时 cancel。
      deadline_timers: %{}
    }

    state =
      case run_load(load_fn) do
        {:ok, restored} ->
          base
          |> Map.merge(restored)
          |> sanitize_loaded_active_set()

        {:error, reason} ->
          CliObserve.emit("voxel_transaction_coordinator_persist_load_failed", fn ->
            %{reason: inspect(reason)}
          end)

          base
      end

    # 重启后:活跃事务的 deadline 重新 arm(让 liveness 在重启后续命),周期
    # sweep 也启动。
    state = rearm_all_deadlines(state)
    schedule_periodic_sweep(state)

    {:ok, state}
  end

  # Phase 4 (D2):default sequence-backed allocator. Tests inject a stubbed
  # `next_object_id_fn` opt so they don't depend on Postgres directly.
  defp default_next_object_id do
    DataService.Voxel.SceneObjectStore.next_object_id()
  end

  @impl true
  def handle_call(message, from, state) do
    case do_handle_call(message, from, state) do
      {:reply, _reply, ^state} = ret ->
        ret

      {:reply, reply, next_state} ->
        # 阶段4 / world-2pc-4:行级增量 + 异步 flush。do_handle_call 内的
        # put/record/archive 帮手已把变更/删除的 transaction_id 累进
        # dirty_rows / deleted_rows;这里只负责"安排一次异步 flush",不在
        # 回复路径上同步写 DB。
        {:reply, reply, schedule_flush(next_state)}
    end
  end

  # 阶段4 / world-2pc-4:把脏行 flush 排成一条 :flush_dirty_rows 异步消息。同一
  # 回合多笔变更只排一次(flush_scheduled? 守门),降低 DB 往返,且回复调用方不
  # 等 DB。
  defp schedule_flush(%{dirty_rows: dirty, deleted_rows: deleted} = state) do
    cond do
      state.flush_scheduled? ->
        state

      MapSet.size(dirty) == 0 and MapSet.size(deleted) == 0 ->
        state

      true ->
        send(self(), :flush_dirty_rows)
        %{state | flush_scheduled?: true}
    end
  end

  @impl true
  def handle_info(:flush_dirty_rows, state) do
    {:noreply, flush_dirty_rows(state)}
  end

  # 周期 deadline sweep:liveness 兜底(主路径是 per-deadline timer)。
  def handle_info(:periodic_sweep, state) do
    {_actions, swept} = do_sweep_deadlines(state)
    schedule_periodic_sweep(swept)
    {:noreply, schedule_flush(swept)}
  end

  # 单笔事务的 deadline 到点。
  def handle_info({:deadline, transaction_id, decision_version}, state) do
    swept = advance_one_deadline(state, transaction_id, decision_version)
    {:noreply, schedule_flush(swept)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp flush_dirty_rows(%{persist_rows_fn: nil} = state) do
    %{state | dirty_rows: MapSet.new(), deleted_rows: MapSet.new(), flush_scheduled?: false}
  end

  defp flush_dirty_rows(%{persist_rows_fn: persist_rows_fn} = state)
       when is_function(persist_rows_fn, 2) do
    changed_rows =
      state.dirty_rows
      |> Enum.map(fn transaction_id -> {transaction_id, build_row(state, transaction_id)} end)

    deleted_ids = MapSet.to_list(state.deleted_rows)

    case persist_rows_fn.(changed_rows, deleted_ids) do
      :ok ->
        :ok

      {:error, reason} ->
        CliObserve.emit("voxel_transaction_coordinator_persist_failed", fn ->
          %{reason: inspect(reason), changed: length(changed_rows), deleted: length(deleted_ids)}
        end)
    end

    %{state | dirty_rows: MapSet.new(), deleted_rows: MapSet.new(), flush_scheduled?: false}
  end

  # 一行 = 一笔事务的可恢复全量:active 事务带完整 struct + fingerprint +
  # 最新 decision_index 归档记录;已被裁出活跃集的终态事务只剩 decision_index
  # 归档记录(struct/fingerprint 为 nil)。
  defp build_row(state, transaction_id) do
    %{
      transaction_id: transaction_id,
      transaction: Map.get(state.transactions, transaction_id),
      begin_fingerprint: Map.get(state.begin_fingerprints, transaction_id),
      decision_index: Map.get(state.decision_index, transaction_id)
    }
  end

  defp mark_dirty(state, transaction_id) do
    %{
      state
      | dirty_rows: MapSet.put(state.dirty_rows, transaction_id),
        deleted_rows: MapSet.delete(state.deleted_rows, transaction_id)
    }
  end

  defp do_handle_call({:begin_transaction, attrs}, _from, state) do
    case build_transaction(attrs, state) do
      {:ok, transaction, fingerprint} ->
        {reply, next_state} = put_new_transaction(state, transaction, fingerprint)
        {:reply, reply, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_handle_call({:prepare_ack, transaction_id, ack}, _from, state) do
    with {:ok, transaction} <- fetch_transaction(state, transaction_id),
         {:ok, normalized_ack} <- normalize_prepare_ack(ack),
         {:ok, next_transaction} <- apply_prepare_ack(transaction, normalized_ack) do
      next_state =
        if next_transaction != transaction do
          emit_prepare_ack(next_transaction, normalized_ack)

          state
          |> put_in([:transactions, transaction_id], next_transaction)
          |> mark_dirty(transaction_id)
        else
          state
        end

      {:reply, {:ok, next_transaction}, next_state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_handle_call({:decision, transaction_id, decision_version, decision}, _from, state) do
    with {:ok, decision_version} <- normalize_decision_version(decision_version),
         {:active, {:ok, transaction}} <-
           {:active, fetch_transaction(state, transaction_id)},
         :ok <- validate_decision_version(transaction, decision_version),
         :new <- decision_replay(state, transaction_id, decision_version, decision),
         {:ok, next_transaction} <- apply_decision(transaction, decision) do
      next_state =
        state
        |> record_decision(next_transaction, decision, decision_version)
        |> maybe_finalize_after_decision(next_transaction)

      emit_decision(next_transaction, decision)

      reply_transaction = current_transaction(next_state, transaction_id, next_transaction)
      {:reply, {:ok, reply_transaction}, next_state}
    else
      {:replay, transaction} ->
        {:reply, {:ok, transaction}, state}

      # 阶段4 / world-2pc-4:事务已被裁出活跃集(终态归档后,或重启从行级 store
      # 恢复时 transaction: nil 只剩归档)。decision 不能直接报 :unknown_transaction
      # ——必须按 `decision_index` 归档做幂等判定。**关键不变式**:"终态移出活跃集"
      # (同进程归档)与 "重启从库恢复活跃集"(load 后只剩归档)对同一笔归档事务的
      # 重决策必须表现一致——本分支同时覆盖这两种归档形态。
      {:active, {:error, :unknown_transaction}} ->
        archived_decision_reply(state, transaction_id, decision_version, decision)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # 阶段4 / world-2pc-3:participant durable-ack 屏障。只接受 decided-commit 区
  # (`:committing` / `:committed`)的事务;全部 participant durable 后推进到
  # `:committed` 并 cancel deadline + 归档裁剪。
  defp do_handle_call({:commit_durable_ack, transaction_id, participant_key}, _from, state) do
    case lookup_active(state, transaction_id) do
      {:ok, %BuildTransaction{state: :committed} = committed} ->
        # 已经全 durable,幂等。
        {:reply, {:ok, committed}, state}

      {:ok, %BuildTransaction{state: :committing} = transaction} ->
        case Map.fetch(transaction.commit_acks, participant_key) do
          {:ok, _status} ->
            next_acks = Map.put(transaction.commit_acks, participant_key, :durable)
            next_transaction = %{transaction | commit_acks: next_acks}

            staged_state =
              state
              |> put_in([:transactions, transaction_id], next_transaction)
              |> mark_dirty(transaction_id)

            emit_commit_durable_ack(next_transaction, participant_key)

            {reply_transaction, next_state} =
              maybe_complete_commit(staged_state, next_transaction)

            {:reply, {:ok, reply_transaction}, next_state}

          :error ->
            {:reply, {:error, {:unknown_participant, participant_key}}, state}
        end

      {:ok, _other} ->
        {:reply, {:error, :not_committing}, state}

      :error ->
        # 终态归档后再来 ack:若归档显示已 commit,幂等成功;否则未知。
        case Map.fetch(state.decision_index, transaction_id) do
          {:ok, %{decision: :commit}} -> {:reply, {:ok, :committed}, state}
          _ -> {:reply, {:error, :unknown_transaction}, state}
        end
    end
  end

  defp do_handle_call({:fetch_active, transaction_id}, _from, state) do
    {:reply, lookup_active(state, transaction_id), state}
  end

  defp do_handle_call(:sweep_deadlines, _from, state) do
    {actions, swept} = do_sweep_deadlines(state)
    {:reply, actions, swept}
  end

  defp do_handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  # 对已归档(不在活跃集)的事务回放 decision:
  #   * 同 (decision, version) → 幂等 `{:ok, 终态视图}`(与活跃路径 decision_replay
  #     命中 `decisions` 时返回 `{:ok, struct}` 语义一致;归档后 struct 已裁出,
  #     这里合成等价的终态视图)。
  #   * 异 decision / 异 version → `{:already_decided, decided, version}`
  #     (契约#2 已决不可逆)。
  #   * 真未知事务 → :unknown_transaction。
  defp archived_decision_reply(state, transaction_id, decision_version, decision) do
    case Map.fetch(state.decision_index, transaction_id) do
      {:ok, %{decision: ^decision, decision_version: ^decision_version}} ->
        {:reply, {:ok, archived_terminal_view(transaction_id, decision, decision_version)}, state}

      {:ok, %{decision: decided, decision_version: decided_version}} ->
        {:reply, {:error, {:already_decided, decided, decided_version}}, state}

      :error ->
        {:reply, {:error, :unknown_transaction}, state}
    end
  end

  # 归档记录足够回答"这笔已决、决了什么"——合成最小一致的终态视图用于幂等回复。
  # 归档事务已裁出活跃集,完整字段(participants / intents 等)不再常驻;视图只
  # 保证 `transaction_id` / `decision_version` / `state` 对得上,其余 @enforce_keys
  # 置 nil 占位(调用方只关心终态,见 transaction_coordinator_test / 持久化测试)。
  defp archived_terminal_view(transaction_id, decision, decision_version) do
    %BuildTransaction{
      transaction_id: transaction_id,
      logical_scene_id: nil,
      parcel_id: nil,
      reservation_id: nil,
      participants: [],
      intent_hash: nil,
      decision_version: decision_version,
      timeout_at_ms: nil,
      state: terminal_state_for(decision)
    }
  end

  defp terminal_state_for(:commit), do: :committed
  defp terminal_state_for(:abort), do: :aborted

  defp put_new_transaction(state, transaction, fingerprint) do
    transaction_id = transaction.transaction_id

    cond do
      Map.has_key?(state.transactions, transaction_id) ->
        existing = Map.fetch!(state.transactions, transaction_id)

        if state.begin_fingerprints[transaction_id] == fingerprint do
          {{:ok, existing}, state}
        else
          {{:error, :transaction_conflict}, state}
        end

      # 阶段4 / world-2pc-4:已被裁出活跃集的终态事务,begin replay 命中归档。
      # 返回幂等结果而非 :transaction_conflict(避免重启后裁剪导致 replay 误判)。
      Map.has_key?(state.decision_index, transaction_id) ->
        archived = Map.fetch!(state.decision_index, transaction_id)
        {{:ok, archived_transaction_view(transaction, archived)}, state}

      true ->
        next_state =
          state
          |> put_in([:transactions, transaction_id], transaction)
          |> put_in([:begin_fingerprints, transaction_id], fingerprint)
          |> mark_dirty(transaction_id)
          |> arm_deadline(transaction)

        emit_begin(transaction)
        {{:ok, transaction}, next_state}
    end
  end

  # begin replay 命中终态归档时,合成一个最小一致视图:用新算出的 participants
  # (replay 不重新分配 object,所以 scene_objects 为空),套上归档里的终态。
  defp archived_transaction_view(transaction, %{decision: :commit}) do
    %{transaction | state: :committed}
  end

  defp archived_transaction_view(transaction, %{decision: :abort}) do
    %{transaction | state: :aborted}
  end

  defp apply_prepare_ack(%BuildTransaction{state: state} = transaction, _ack)
       when state in [:committed, :aborted] do
    {:ok, transaction}
  end

  defp apply_prepare_ack(transaction, ack) do
    participant_key = ack.participant_key

    case find_participant(transaction.participants, participant_key) do
      nil ->
        {:error, :unknown_participant}

      participant ->
        next_prepare_status = ack.prepare_status

        cond do
          participant.prepare_status == next_prepare_status ->
            {:ok, transaction}

          participant.prepare_status != :pending ->
            {:error, :prepare_ack_conflict}

          true ->
            participant = %{
              participant
              | prepare_status: next_prepare_status,
                last_ack_ms: ack.acked_at_ms
            }

            participants =
              replace_participant(transaction.participants, participant_key, participant)

            {:ok, %{transaction | participants: participants, state: prepare_state(participants)}}
        end
    end
  end

  # 阶段4 / world-2pc-3:commit decision **已决**,但只进 `:committing`——必须
  # 等全 participant durable-ack 才到 `:committed`(契约#3)。同时初始化
  # commit_acks 为全 :pending,driver/reaper 据此判断还差哪些 durable-ack。
  defp apply_decision(%BuildTransaction{state: :prepared} = transaction, :commit) do
    {:ok,
     %{
       transaction
       | state: :committing,
         participants: mark_commit_status(transaction.participants, :committing),
         commit_acks: init_commit_acks(transaction.participants)
     }}
  end

  defp apply_decision(%BuildTransaction{state: state}, :commit)
       when state in [:preparing, :aborting] do
    {:error, :not_prepared}
  end

  defp apply_decision(%BuildTransaction{state: :aborted}, :commit) do
    {:error, {:already_decided, :abort}}
  end

  # 已在 commit 已决区(committing/committed)再 commit:幂等,不报错(支持
  # driver 重投递时再次 commit_decision)。
  defp apply_decision(%BuildTransaction{state: state} = transaction, :commit)
       when state in [:committing, :committed] do
    {:ok, transaction}
  end

  defp apply_decision(%BuildTransaction{state: state} = transaction, :abort)
       when state in @abortable_states do
    {:ok,
     %{
       transaction
       | state: :aborted,
         participants: mark_commit_status(transaction.participants, :aborted)
     }}
  end

  # 契约#2:commit decision 已记录后(`:committing` / `:committed`)绝不能 abort。
  # 拒绝 abort,让调用方知道这笔已决,只能重投递到 :committed。
  defp apply_decision(%BuildTransaction{state: state}, :abort)
       when state in [:committing, :committed] do
    {:error, {:already_decided, :commit}}
  end

  defp apply_decision(%BuildTransaction{state: :aborted}, :abort) do
    {:error, {:already_decided, :abort}}
  end

  defp init_commit_acks(participants) do
    Enum.into(participants, %{}, fn participant ->
      {participant_key(participant), :pending}
    end)
  end

  defp decision_replay(state, transaction_id, decision_version, decision) do
    case Map.fetch(state.decisions, {transaction_id, decision_version}) do
      {:ok, %{decision: ^decision}} ->
        {:replay, Map.fetch!(state.transactions, transaction_id)}

      # 同 pair 已记录**另一个**决策(典型:事务已 commit-decided / :committing,
      # 现在又来 abort)。对仍在活跃集的事务,把契约#2 的"已决不可逆"判定交回
      # `apply_decision`——它按事务当前 state 给出精确的 {:already_decided, 已决
      # decision}(而非泛化的 :decision_conflict)。返回 `:new` 让 with 链继续到
      # apply_decision;active 事务的 state 一定能让 apply_decision 拒绝(它绝不会
      # 真的应用相反决策)。
      {:ok, %{decision: _other_decision}} ->
        :new

      :error ->
        case Map.fetch(state.decision_index, transaction_id) do
          {:ok, %{decision: other_decision, decision_version: other_version}} ->
            {:error, {:already_decided, other_decision, other_version}}

          :error ->
            :new
        end
    end
  end

  defp record_decision(state, transaction, decision, decision_version) do
    decision_record = %{
      transaction_id: transaction.transaction_id,
      decision_version: decision_version,
      decision: decision,
      state: transaction.state,
      decided_at_ms: now_ms()
    }

    state
    |> put_in([:transactions, transaction.transaction_id], transaction)
    |> put_in([:decisions, {transaction.transaction_id, decision_version}], decision_record)
    # 阶段4 / world-2pc-4:`decision_index` 是**终态决策归档**(供已裁出活跃集的
    # 事务做幂等重放)。`:committing` 是已决但**未终态**的中间态——它仍在活跃集
    # (`transactions`)里,replay 走活跃 struct + apply_decision,**不**写
    # decision_index。只有进入终态(:committed / :aborted)的决策才归档进
    # decision_index(commit 完成走 maybe_complete_commit / abort 走本路径)。
    |> maybe_index_terminal_decision(transaction, decision_record)
    |> mark_dirty(transaction.transaction_id)
    |> prune_decisions()
  end

  defp maybe_index_terminal_decision(state, %BuildTransaction{state: tx_state}, decision_record)
       when tx_state in [:committed, :aborted] do
    put_in(state, [:decision_index, decision_record.transaction_id], decision_record)
  end

  defp maybe_index_terminal_decision(state, _transaction, _decision_record), do: state

  # 阶段4 / world-2pc-4:abort 决策直接进终态 → 立刻归档裁剪;commit 决策只到
  # `:committing`,要等 durable-ack,留在活跃集。
  defp maybe_finalize_after_decision(state, %BuildTransaction{state: :aborted} = transaction) do
    archive_terminal(state, transaction)
  end

  defp maybe_finalize_after_decision(state, _transaction), do: state

  # 阶段4 / world-2pc-3:全 participant durable 后 :committing → :committed,然后
  # 归档裁剪。返回 `{用于回复调用方的事务视图, next_state}`:全 durable 时返回
  # `:committed` 视图(即使已被裁出活跃集),否则返回仍 `:committing` 的事务。
  defp maybe_complete_commit(state, %BuildTransaction{commit_acks: acks} = transaction) do
    if all_durable?(acks) do
      committed = %{
        transaction
        | state: :committed,
          participants: mark_commit_status(transaction.participants, :committed)
      }

      decided = %{
        transaction_id: committed.transaction_id,
        decision_version: committed.decision_version,
        decision: :commit,
        state: :committed,
        decided_at_ms: now_ms()
      }

      emit_committed(committed)

      next_state =
        state
        |> put_in([:transactions, committed.transaction_id], committed)
        |> put_in([:decisions, {committed.transaction_id, committed.decision_version}], decided)
        |> put_in([:decision_index, committed.transaction_id], decided)
        |> mark_dirty(committed.transaction_id)
        |> archive_terminal(committed)

      {committed, next_state}
    else
      {transaction, state}
    end
  end

  defp all_durable?(acks) do
    acks != %{} and Enum.all?(acks, fn {_key, status} -> status == :durable end)
  end

  # 阶段4 / world-2pc-4:终态事务移出活跃 map(transactions / begin_fingerprints /
  # deadline_timers),只在 decision_index 留轻量归档记录。这条事务行仍被
  # mark_dirty 过(decision/committed 路径已经标过),flush 时 build_row 会带上
  # transaction: nil + decision_index 归档,把 DB 行收敛成轻量历史行。
  defp archive_terminal(state, %BuildTransaction{transaction_id: transaction_id}) do
    state
    |> cancel_deadline(transaction_id)
    |> update_in([:transactions], &Map.delete(&1, transaction_id))
    |> update_in([:begin_fingerprints], &Map.delete(&1, transaction_id))
    |> mark_dirty(transaction_id)
  end

  # `decisions` map 是有界终态决策窗口:超过 @decision_retention 时裁掉最旧的
  # 已归档(不在活跃集)决策记录。活跃事务的决策(:committing 还在 transactions
  # 里)永不裁,确保 in-flight 重放仍能命中完整记录。
  defp prune_decisions(state) do
    if map_size(state.decisions) <= @decision_retention do
      state
    else
      archived_keys =
        state.decisions
        |> Enum.reject(fn {{tx_id, _dv}, _record} ->
          Map.has_key?(state.transactions, tx_id)
        end)
        |> Enum.sort_by(fn {_key, record} -> record.decided_at_ms end)

      drop_count = map_size(state.decisions) - @decision_retention

      keys_to_drop =
        archived_keys
        |> Enum.take(drop_count)
        |> Enum.map(fn {key, _record} -> key end)

      update_in(state.decisions, fn decisions ->
        Enum.reduce(keys_to_drop, decisions, &Map.delete(&2, &1))
      end)
    end
  end

  # 优先返回活跃集里的最新 struct;若已被裁出(到终态),返回传入的快照
  # (commit 完成路径已合成 committed struct)。
  defp current_transaction(state, transaction_id, fallback) do
    Map.get(state.transactions, transaction_id, fallback)
  end

  defp lookup_active(state, transaction_id) do
    case Map.fetch(state.transactions, transaction_id) do
      {:ok, transaction} -> {:ok, transaction}
      :error -> :error
    end
  end

  defp validate_decision_version(transaction, decision_version) do
    if transaction.decision_version == decision_version do
      :ok
    else
      {:error, {:decision_version_mismatch, transaction.decision_version}}
    end
  end

  defp build_transaction(attrs, state) do
    attrs = attrs_map(attrs)

    transaction_id = value(attrs, :transaction_id, unique_transaction_id())

    # Phase 4 (D2):skip allocation entirely on replay so the sequence is not
    # advanced on every begin_transaction retry. The replay path returns the
    # already-stored transaction (with its original object_id values).
    #
    # 阶段4 / world-2pc-4:活跃集裁剪后,已归档的终态事务不在 `transactions` 里。
    # replay 命中归档(`decision_index`)时也走"不分配"分支,避免对已终态事务的
    # begin replay 浪费 object_id sequence;`put_new_transaction` 再按归档返回幂等
    # 终态视图。
    known? =
      Map.has_key?(state.transactions, transaction_id) or
        Map.has_key?(state.decision_index, transaction_id)

    case known? do
      true ->
        with {:ok, participants} <- fetch_participants(attrs),
             {:ok, decision_version} <-
               normalize_decision_version(value(attrs, :decision_version, 1)),
             {:ok, intents_by_participant} <- normalize_intents_by_participant(attrs) do
          # Build a fingerprint matching the existing transaction so
          # `put_new_transaction` returns `{:ok, existing}`. `scene_objects`
          # is intentionally absent from the fingerprint (allocations are not
          # part of "is this the same transaction" identity).
          transaction = %BuildTransaction{
            transaction_id: transaction_id,
            logical_scene_id: value(attrs, :logical_scene_id),
            parcel_id: value(attrs, :parcel_id),
            reservation_id: value(attrs, :reservation_id),
            participants: participants,
            intent_hash: value(attrs, :intent_hash, default_intent_hash(attrs, participants)),
            decision_version: decision_version,
            timeout_at_ms: value(attrs, :timeout_at_ms, now_ms() + @default_timeout_ms),
            state: :preparing,
            intents_by_participant: intents_by_participant,
            scene_objects: []
          }

          {:ok, transaction, begin_fingerprint(transaction)}
        end

      false ->
        with {:ok, participants} <- fetch_participants(attrs),
             {:ok, decision_version} <-
               normalize_decision_version(value(attrs, :decision_version, 1)),
             {:ok, intents_by_participant} <- normalize_intents_by_participant(attrs),
             {:ok, scene_objects} <-
               allocate_scene_objects(attrs, state.next_object_id_fn, participants) do
          transaction = %BuildTransaction{
            transaction_id: transaction_id,
            logical_scene_id: value(attrs, :logical_scene_id),
            parcel_id: value(attrs, :parcel_id),
            reservation_id: value(attrs, :reservation_id),
            participants: participants,
            intent_hash: value(attrs, :intent_hash, default_intent_hash(attrs, participants)),
            decision_version: decision_version,
            timeout_at_ms: value(attrs, :timeout_at_ms, now_ms() + @default_timeout_ms),
            state: :preparing,
            intents_by_participant: intents_by_participant,
            scene_objects: scene_objects
          }

          {:ok, transaction, begin_fingerprint(transaction)}
        end
    end
  end

  # Phase 4 (D2 + D3):normalize each scene_object seed and allocate an
  # `object_id` from the sequence. Empty list → no objects to create (e.g.
  # break-only transactions).
  # Phase A4-3:除了分配 object_id,还按 D6 字典序规则推导 owner lease
  # (字典序第一个 covered chunk 在 participant.chunk_owners 中记录的
  # region_id / lease_id)。
  # 任一 covered chunk 不被任何 participant 的 affected_chunks 覆盖时,该 seed
  # 无法选 owner → :scene_object_owner_undeterminable(说明 caller 路由信息
  # 跟 covered_chunks 不一致)。
  defp allocate_scene_objects(attrs, next_object_id_fn, participants) do
    case value(attrs, :scene_objects, []) do
      [] ->
        {:ok, []}

      seeds when is_list(seeds) ->
        logical_scene_id = value(attrs, :logical_scene_id)

        seeds
        |> Enum.reduce_while({:ok, []}, fn seed, {:ok, acc} ->
          with {:ok, normalized} <- normalize_scene_object_seed(seed),
               {:ok, object_id} <- scene_object_id(normalized, next_object_id_fn),
               {:ok, owner} <- derive_scene_object_owner(normalized, participants) do
            entry =
              normalized
              |> Map.put(:logical_scene_id, logical_scene_id)
              |> Map.put(:object_id, object_id)
              |> Map.merge(owner)

            {:cont, {:ok, [entry | acc]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          error -> error
        end

      _other ->
        {:error, :invalid_scene_objects}
    end
  end

  # D6:owner 是字典序(`{x, y, z}` ascending)第一个 covered chunk 的真实
  # lease owner。同一 prefab 的所有 covered chunks 必须落到 transaction
  # participants 的某一个 affected_chunks(否则 caller 路由信息错位)。
  defp derive_scene_object_owner(normalized_seed, participants) do
    case Enum.sort(normalized_seed.covered_chunks) do
      [] ->
        {:error, :invalid_covered_chunks}

      [first_chunk | _] ->
        case Enum.find(participants, fn p -> first_chunk in p.affected_chunks end) do
          nil ->
            {:error, :scene_object_owner_undeterminable}

          participant ->
            case Map.fetch(participant.chunk_owners, first_chunk) do
              {:ok, {region_id, lease_id}} ->
                {:ok,
                 %{
                   owner_region_id: region_id,
                   owner_lease_id: lease_id
                 }}

              :error ->
                {:error, {:missing_chunk_owner, first_chunk}}
            end
        end
    end
  end

  defp run_next_object_id(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, id} when is_integer(id) and id > 0 -> {:ok, id}
      _ -> {:error, :object_id_unavailable}
    end
  rescue
    _exception -> {:error, :object_id_unavailable}
  end

  defp run_next_object_id(_), do: {:error, :object_id_unavailable}

  defp scene_object_id(%{object_id: object_id}, _next_object_id_fn)
       when is_integer(object_id) and object_id > 0 and object_id <= 0x7FFF_FFFF_FFFF_FFFF,
       do: {:ok, object_id}

  defp scene_object_id(%{object_id: _object_id}, _next_object_id_fn),
    do: {:error, :invalid_object_id}

  defp scene_object_id(_normalized_seed, next_object_id_fn),
    do: run_next_object_id(next_object_id_fn)

  defp normalize_scene_object_seed(seed) when is_map(seed) or is_list(seed) do
    seed = attrs_map(seed)

    with {:ok, blueprint_id} <- required_value(seed, :blueprint_id),
         {:ok, blueprint_version} <- required_value(seed, :blueprint_version),
         {:ok, parcel_id} <- required_value(seed, :parcel_id),
         {:ok, anchor} <- required_value(seed, :anchor_world_micro),
         {:ok, anchor_norm} <- normalize_anchor_world_micro(anchor),
         {:ok, rotation} <- required_value(seed, :rotation),
         {:ok, owner_actor_id} <- required_value(seed, :owner_actor_id),
         {:ok, covered_chunks} <- required_value(seed, :covered_chunks),
         {:ok, covered_chunks_norm} <- normalize_covered_chunks(covered_chunks),
         {:ok, part_states} <- required_value(seed, :part_states),
         {:ok, part_states_norm} <- normalize_part_states(part_states) do
      {:ok,
       %{
         blueprint_id: blueprint_id,
         blueprint_version: blueprint_version,
         parcel_id: parcel_id,
         anchor_world_micro: anchor_norm,
         rotation: rotation,
         owner_actor_id: owner_actor_id,
         covered_chunks: covered_chunks_norm,
         part_states: part_states_norm,
         state_flags: value(seed, :state_flags, 0),
         object_attribute_ref: value(seed, :object_attribute_ref, 0),
         object_tag_set_ref: value(seed, :object_tag_set_ref, 0),
         object_version: value(seed, :object_version, 1)
       }}
      |> maybe_put_scene_object_id(value(seed, :object_id))
    else
      {:error, {:missing, key}} -> {:error, {:missing_scene_object_field, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_scene_object_seed(_), do: {:error, :invalid_scene_object}

  defp maybe_put_scene_object_id({:ok, normalized}, nil), do: {:ok, normalized}

  defp maybe_put_scene_object_id({:ok, normalized}, object_id)
       when is_integer(object_id) and object_id > 0 and object_id <= 0x7FFF_FFFF_FFFF_FFFF do
    {:ok, Map.put(normalized, :object_id, object_id)}
  end

  defp maybe_put_scene_object_id({:ok, _normalized}, _object_id), do: {:error, :invalid_object_id}

  defp maybe_put_scene_object_id(error, _object_id), do: error

  defp normalize_anchor_world_micro({x, y, z})
       when is_integer(x) and is_integer(y) and is_integer(z),
       do: {:ok, {x, y, z}}

  defp normalize_anchor_world_micro([x, y, z])
       when is_integer(x) and is_integer(y) and is_integer(z),
       do: {:ok, {x, y, z}}

  defp normalize_anchor_world_micro(_), do: {:error, :invalid_anchor_world_micro}

  defp normalize_covered_chunks([]), do: {:error, :invalid_covered_chunks}

  defp normalize_covered_chunks(list) when is_list(list) do
    if Enum.all?(list, fn
         {x, y, z} when is_integer(x) and is_integer(y) and is_integer(z) -> true
         _ -> false
       end) do
      {:ok, list}
    else
      {:error, :invalid_covered_chunks}
    end
  end

  defp normalize_covered_chunks(_), do: {:error, :invalid_covered_chunks}

  defp normalize_part_states([]), do: {:error, :invalid_part_states}

  defp normalize_part_states(list) when is_list(list) do
    list
    |> Enum.reduce_while([], fn entry, acc ->
      case normalize_part_state(entry) do
        {:ok, ps} -> {:cont, [ps | acc]}
        {:error, _} -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :invalid_part_states}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp normalize_part_states(_), do: {:error, :invalid_part_states}

  defp normalize_part_state(entry) when is_map(entry) or is_list(entry) do
    entry = attrs_map(entry)

    with {:ok, part_id} <- required_value(entry, :part_id),
         true <- is_integer(part_id) and part_id >= 0,
         {:ok, health} <- required_value(entry, :health),
         true <- is_integer(health) do
      {:ok,
       %{
         part_id: part_id,
         health: health,
         state_flags: value(entry, :state_flags, 0)
       }}
    else
      {:error, _} = err -> err
      false -> {:error, :invalid_part_state}
    end
  end

  defp normalize_part_state(_), do: {:error, :invalid_part_state}

  # Phase 3-bis: optional but typed when present. The shape is the same
  # `intents_by_participant` map `TransactionExecutor.execute/4` consumes:
  # `%{ participant_key => %{chunk_coord => [intent_attrs, ...]} }`.
  # The coordinator persists it as part of the transaction so a Watcher
  # restart can replay commit dispatch.
  defp normalize_intents_by_participant(attrs) do
    case value(attrs, :intents_by_participant, %{}) do
      map when is_map(map) -> {:ok, map}
      _other -> {:error, :invalid_intents_by_participant}
    end
  end

  defp fetch_participants(attrs) do
    case value(attrs, :participants, :missing) do
      :missing -> {:error, {:missing, :participants}}
      participants -> normalize_participants(participants)
    end
  end

  defp normalize_participants(participants) when is_list(participants) do
    participants
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn raw_participant, {:ok, seen, acc} ->
      case normalize_participant(raw_participant) do
        {:ok, participant} ->
          participant_key = participant_key(participant)

          if MapSet.member?(seen, participant_key) do
            {:halt, {:error, {:duplicate_participant, participant_key}}}
          else
            {:cont, {:ok, MapSet.put(seen, participant_key), [participant | acc]}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _seen, normalized} ->
        participants =
          normalized
          |> Enum.reverse()
          |> Enum.sort_by(&participant_key/1)

        {:ok, participants}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_participants(_participants), do: {:error, :invalid_participants}

  defp normalize_participant(%TransactionParticipant{} = participant) do
    affected_chunks = Enum.sort(participant.affected_chunks || [])

    with :ok <- require_present(participant.participant_key, :participant_key),
         :ok <- require_present(participant.assigned_scene_node, :assigned_scene_node),
         {:ok, chunk_owners} <- normalize_chunk_owners(participant.chunk_owners, affected_chunks) do
      {:ok,
       %{
         participant
         | prepare_status: :pending,
           commit_status: :pending,
           last_ack_ms: 0,
           affected_chunks: affected_chunks,
           chunk_owners: chunk_owners
       }}
    end
  end

  defp normalize_participant(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs_map(attrs)

    with {:ok, participant_key} <- required_value(attrs, :participant_key),
         {:ok, region_id} <- required_value(attrs, :region_id),
         {:ok, lease_id} <- required_value(attrs, :lease_id),
         {:ok, owner_scene_instance_ref} <- required_value(attrs, :owner_scene_instance_ref),
         {:ok, owner_epoch} <- required_value(attrs, :owner_epoch),
         {:ok, assigned_scene_node} <- required_value(attrs, :assigned_scene_node),
         {:ok, chunk_owners_raw} <- required_value(attrs, :chunk_owners),
         {:ok, affected_chunks} <- required_value(attrs, :affected_chunks) do
      affected_chunks = Enum.sort(affected_chunks)

      with {:ok, chunk_owners} <- normalize_chunk_owners(chunk_owners_raw, affected_chunks) do
        {:ok,
         %TransactionParticipant{
           participant_key: participant_key,
           region_id: region_id,
           lease_id: lease_id,
           owner_scene_instance_ref: owner_scene_instance_ref,
           owner_epoch: owner_epoch,
           assigned_scene_node: assigned_scene_node,
           affected_chunks: affected_chunks,
           chunk_owners: chunk_owners,
           prepare_status: :pending,
           commit_status: :pending,
           last_ack_ms: 0
         }}
      end
    end
  end

  defp normalize_participant(_attrs), do: {:error, :invalid_participant}

  defp normalize_prepare_ack(ack) do
    ack = attrs_map(ack)

    with {:ok, participant_key} <- required_value(ack, :participant_key),
         {:ok, status} <- required_value(ack, :status),
         {:ok, prepare_status} <- normalize_prepare_status(status) do
      {:ok,
       %{
         participant_key: participant_key,
         region_id: value(ack, :region_id),
         lease_id: value(ack, :lease_id),
         prepare_status: prepare_status,
         acked_at_ms: value(ack, :acked_at_ms, now_ms())
       }}
    end
  end

  defp normalize_prepare_status(status) when status in @prepare_success_statuses do
    {:ok, :prepared}
  end

  defp normalize_prepare_status(status) when status in @prepare_failure_statuses do
    {:ok, :failed}
  end

  defp normalize_prepare_status("prepared"), do: {:ok, :prepared}
  defp normalize_prepare_status("ok"), do: {:ok, :prepared}
  defp normalize_prepare_status("failed"), do: {:ok, :failed}
  defp normalize_prepare_status("rejected"), do: {:ok, :failed}
  defp normalize_prepare_status("error"), do: {:ok, :failed}
  defp normalize_prepare_status("aborted"), do: {:ok, :failed}
  defp normalize_prepare_status(_status), do: {:error, :invalid_prepare_status}

  defp prepare_state(participants) do
    cond do
      Enum.any?(participants, &(&1.prepare_status == :failed)) ->
        :aborting

      Enum.all?(participants, &(&1.prepare_status == :prepared)) ->
        :prepared

      true ->
        :preparing
    end
  end

  defp mark_commit_status(participants, commit_status) do
    Enum.map(participants, &%{&1 | commit_status: commit_status})
  end

  defp find_participant(participants, participant_key) do
    Enum.find(participants, &(participant_key(&1) == participant_key))
  end

  defp replace_participant(participants, participant_key, next_participant) do
    Enum.map(participants, fn participant ->
      if participant_key(participant) == participant_key do
        next_participant
      else
        participant
      end
    end)
  end

  defp fetch_transaction(state, transaction_id) do
    case Map.fetch(state.transactions, transaction_id) do
      {:ok, transaction} -> {:ok, transaction}
      :error -> {:error, :unknown_transaction}
    end
  end

  # ── 阶段4 / world-2pc-2 deadline 调度(liveness 内生)─────────────────

  # begin 时按 timeout_at_ms 安排单笔 deadline。timeout_at_ms 是 wall-clock
  # (System.system_time(:millisecond)),换算成相对延迟 send_after。已过期的事务
  # 安排 0ms,让它在下一轮立刻被推进。
  defp arm_deadline(%{deadline_enabled?: false} = state, _transaction), do: state

  defp arm_deadline(state, %BuildTransaction{timeout_at_ms: timeout_at_ms} = transaction)
       when is_integer(timeout_at_ms) do
    transaction_id = transaction.transaction_id
    delay = timeout_at_ms |> Kernel.-(now_ms()) |> max(0) |> min(@max_timer_delay_ms)

    state = cancel_deadline(state, transaction_id)

    ref =
      Process.send_after(
        self(),
        {:deadline, transaction_id, transaction.decision_version},
        delay
      )

    put_in(state.deadline_timers[transaction_id], ref)
  end

  # 兜底:任何**不是带合法 `timeout_at_ms` 的 `%BuildTransaction{}`** 的事务值
  # ——典型是从持久化层 load 回来的 plain map(跨版本残留 / 字段缺失的旧行)或
  # `timeout_at_ms` 为 nil 的半成品事务——不 arm deadline(没有可换算的 wall-clock
  # deadline)。这类行不能在 boot rearm 路径上 crash 掉整个 coordinator;recovery
  # watcher 的 plain-map stale-abort 路径(transaction_recovery_watcher.ex)会把它们
  # 滚到终态。周期 sweep 也会兜底。
  defp arm_deadline(state, _transaction), do: state

  defp cancel_deadline(state, transaction_id) do
    case Map.fetch(state.deadline_timers, transaction_id) do
      {:ok, ref} ->
        Process.cancel_timer(ref)
        update_in(state.deadline_timers, &Map.delete(&1, transaction_id))

      :error ->
        state
    end
  end

  # 以固定 backoff 重排 per-transaction 定时器,不改 timeout_at_ms。用于
  # `:prepared` flag-for-resume:让定时器隔一段再触发,但事务对 reaper 仍是 stale。
  defp rearm_deadline_with_backoff(%{deadline_enabled?: false} = state, _transaction_id, _backoff),
    do: state

  defp rearm_deadline_with_backoff(state, transaction_id, backoff_ms) do
    case Map.fetch(state.transactions, transaction_id) do
      {:ok, %BuildTransaction{decision_version: dv}} ->
        state = cancel_deadline(state, transaction_id)
        ref = Process.send_after(self(), {:deadline, transaction_id, dv}, backoff_ms)
        put_in(state.deadline_timers[transaction_id], ref)

      :error ->
        state
    end
  end

  defp rearm_all_deadlines(%{deadline_enabled?: false} = state), do: state

  defp rearm_all_deadlines(state) do
    Enum.reduce(Map.values(state.transactions), state, fn transaction, acc ->
      arm_deadline(acc, transaction)
    end)
  end

  defp schedule_periodic_sweep(%{deadline_enabled?: false}), do: :ok

  defp schedule_periodic_sweep(%{sweep_interval_ms: interval}) when is_integer(interval) do
    Process.send_after(self(), :periodic_sweep, interval)
    :ok
  end

  # 单笔 deadline 到点:只对仍卡在 :preparing / :prepared 的事务动作。
  defp advance_one_deadline(state, transaction_id, decision_version) do
    state = update_in(state.deadline_timers, &Map.delete(&1, transaction_id))

    case Map.fetch(state.transactions, transaction_id) do
      {:ok, %BuildTransaction{decision_version: ^decision_version} = transaction} ->
        {_action, next_state} = advance_stuck_transaction(state, transaction)
        next_state

      _ ->
        state
    end
  end

  # 全量 deadline sweep(周期兜底 + recovery reaper 手动触发)。返回每笔事务的
  # 动作:卡 :preparing 过期 → abort;卡 :prepared 过期 → 标记待 resume(交回
  # reaper/driver 真正 dispatch commit,coordinator 没有 scene caller)。
  # :committing 不在这里超时——它已决,只能等 durable-ack / driver 重投递。
  defp do_sweep_deadlines(state) do
    now = now_ms()

    Enum.reduce(Map.values(state.transactions), {[], state}, fn transaction,
                                                                {actions, acc_state} ->
      cond do
        # 兜底:只对带合法 `timeout_at_ms` 的 `%BuildTransaction{}` 做 deadline 推进。
        # plain-map 残留行(无 timeout_at_ms / 跨版本字段缺失)在此跳过,交给
        # recovery watcher 的 stale-abort 路径处理,避免 sweep 访问缺失字段 crash。
        sweepable_stuck?(transaction, now) ->
          {action, next_state} = advance_stuck_transaction(acc_state, transaction)
          {[{transaction.transaction_id, action} | actions], next_state}

        true ->
          {actions, acc_state}
      end
    end)
    |> then(fn {actions, next_state} -> {Enum.reverse(actions), next_state} end)
  end

  # 只有带合法 `timeout_at_ms` 的 `%BuildTransaction{}` 且仍卡在 :preparing /
  # :prepared 且已过期,才在 sweep 里推进。
  defp sweepable_stuck?(
         %BuildTransaction{state: tx_state, timeout_at_ms: timeout_at_ms},
         now
       )
       when is_integer(timeout_at_ms) and tx_state in [:preparing, :prepared] do
    timeout_at_ms <= now
  end

  defp sweepable_stuck?(_transaction, _now), do: false

  defp advance_stuck_transaction(state, %BuildTransaction{state: :preparing} = transaction) do
    # 卡在 preparing:participant 没全 prepared,自我 abort 到终态。
    {:ok, aborted} = apply_decision(transaction, :abort)
    emit_deadline_advance(transaction, :advanced_to_abort)

    next_state =
      state
      |> record_decision(aborted, :abort, aborted.decision_version)
      |> archive_terminal(aborted)

    {:advanced_to_abort, next_state}
  end

  defp advance_stuck_transaction(state, %BuildTransaction{state: :prepared} = transaction) do
    # 卡在 prepared:已经全 prepared 但 commit 没推进(典型:driver 崩在
    # decision 之前)。coordinator 不直接 dispatch commit(它没有 scene
    # caller),只 emit 信号让 reaper/driver 接手。
    #
    # **不**改 `timeout_at_ms`(保持 stale,这样 reaper 的 only_stale? 仍会拾起
    # 它续推);只把 per-transaction 定时器以一个固定 backoff 重排,避免在事务
    # 状态真正改变前(被 driver 推到 :committing/:committed)疯狂自触发。
    emit_deadline_advance(transaction, :flagged_for_resume)

    next_state = rearm_deadline_with_backoff(state, transaction.transaction_id, @flag_backoff_ms)

    {:flagged_for_resume, next_state}
  end

  defp advance_stuck_transaction(state, _transaction), do: {:noop, state}

  defp begin_fingerprint(transaction) do
    %{
      transaction_id: transaction.transaction_id,
      logical_scene_id: transaction.logical_scene_id,
      parcel_id: transaction.parcel_id,
      reservation_id: transaction.reservation_id,
      participants: Enum.map(transaction.participants, &participant_fingerprint/1),
      intent_hash: transaction.intent_hash,
      decision_version: transaction.decision_version
    }
  end

  defp participant_fingerprint(participant) do
    %{
      participant_key: participant_key(participant),
      region_id: participant.region_id,
      lease_id: participant.lease_id,
      owner_scene_instance_ref: participant.owner_scene_instance_ref,
      owner_epoch: participant.owner_epoch,
      assigned_scene_node: participant.assigned_scene_node,
      chunk_owners: participant.chunk_owners,
      affected_chunks: participant.affected_chunks
    }
  end

  defp participant_key(%{participant_key: participant_key}) when not is_nil(participant_key),
    do: participant_key

  defp require_present(nil, field), do: {:error, {:missing, field}}
  defp require_present(_value, _field), do: :ok

  defp normalize_chunk_owners(raw, affected_chunks) when is_map(raw) do
    with {:ok, normalized} <-
           Enum.reduce_while(raw, {:ok, %{}}, fn {chunk_coord, owner}, {:ok, acc} ->
             with {:ok, coord} <- coord_tuple(chunk_coord),
                  {:ok, owner_key} <- owner_tuple(owner) do
               {:cont, {:ok, Map.put(acc, coord, owner_key)}}
             else
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end),
         :ok <- ensure_chunk_owners_cover_affected(normalized, affected_chunks) do
      {:ok, normalized}
    end
  end

  defp normalize_chunk_owners(_raw, _affected_chunks), do: {:error, :invalid_chunk_owners}

  defp coord_tuple({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {:ok, {x, y, z}}

  defp coord_tuple([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {:ok, {x, y, z}}

  defp coord_tuple(other), do: {:error, {:invalid_chunk_owner_coord, other}}

  defp owner_tuple({region_id, lease_id}), do: {:ok, {region_id, lease_id}}
  defp owner_tuple([region_id, lease_id]), do: {:ok, {region_id, lease_id}}

  defp owner_tuple(%{region_id: region_id, lease_id: lease_id}),
    do: {:ok, {region_id, lease_id}}

  defp owner_tuple(%{"region_id" => region_id, "lease_id" => lease_id}),
    do: {:ok, {region_id, lease_id}}

  defp owner_tuple(other), do: {:error, {:invalid_chunk_owner, other}}

  defp ensure_chunk_owners_cover_affected(chunk_owners, affected_chunks) do
    missing =
      affected_chunks
      |> Enum.reject(&Map.has_key?(chunk_owners, &1))

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_chunk_owners, missing}}
    end
  end

  defp default_intent_hash(attrs, participants) do
    :erlang.phash2({
      value(attrs, :logical_scene_id),
      value(attrs, :parcel_id),
      value(attrs, :reservation_id),
      Enum.map(participants, &participant_fingerprint/1)
    })
  end

  defp normalize_decision_version(version) when is_integer(version) and version > 0 do
    {:ok, version}
  end

  defp normalize_decision_version(_version), do: {:error, :invalid_decision_version}

  defp required_value(attrs, key) do
    case fetch_value(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing, key}}
    end
  end

  defp value(attrs, key, default \\ nil) do
    case fetch_value(attrs, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_value(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp snapshot_from_state(state) do
    %{
      transactions: state.transactions,
      decisions: state.decisions,
      decision_index: state.decision_index,
      transaction_count: map_size(state.transactions),
      # 阶段4 / world-2pc-4:活跃工作集大小,观测裁剪是否生效。
      active_count: map_size(state.transactions),
      decision_count: map_size(state.decisions)
    }
  end

  defp emit_begin(transaction) do
    CliObserve.emit("voxel_transaction_begin", fn ->
      %{
        transaction_id: transaction.transaction_id,
        decision_version: transaction.decision_version,
        state: transaction.state,
        participants: Enum.map(transaction.participants, &participant_key/1)
      }
    end)
  end

  defp emit_prepare_ack(transaction, ack) do
    CliObserve.emit("voxel_transaction_prepare_ack", fn ->
      %{
        transaction_id: transaction.transaction_id,
        decision_version: transaction.decision_version,
        participant_key: ack.participant_key,
        region_id: ack.region_id,
        lease_id: ack.lease_id,
        prepare_status: ack.prepare_status,
        state: transaction.state
      }
    end)
  end

  defp emit_decision(transaction, decision) do
    CliObserve.emit("voxel_transaction_decision", fn ->
      %{
        transaction_id: transaction.transaction_id,
        decision_version: transaction.decision_version,
        decision: decision,
        state: transaction.state
      }
    end)
  end

  defp emit_commit_durable_ack(transaction, participant_key) do
    CliObserve.emit("voxel_transaction_commit_durable_ack", fn ->
      %{
        transaction_id: transaction.transaction_id,
        decision_version: transaction.decision_version,
        participant_key: inspect(participant_key),
        state: transaction.state,
        pending_acks:
          transaction.commit_acks
          |> Enum.count(fn {_key, status} -> status == :pending end)
      }
    end)
  end

  defp emit_committed(transaction) do
    CliObserve.emit("voxel_transaction_committed", fn ->
      %{
        transaction_id: transaction.transaction_id,
        decision_version: transaction.decision_version,
        state: :committed,
        participant_count: length(transaction.participants)
      }
    end)
  end

  defp emit_deadline_advance(transaction, action) do
    CliObserve.emit("voxel_transaction_deadline_advance", fn ->
      %{
        transaction_id: transaction.transaction_id,
        decision_version: transaction.decision_version,
        from_state: transaction.state,
        action: action
      }
    end)
  end

  defp unique_transaction_id do
    {:voxel_transaction, System.unique_integer([:positive, :monotonic])}
  end

  defp now_ms, do: System.system_time(:millisecond)

  # 阶段4 / world-2pc-4:活跃工作集**契约上只含 `%BuildTransaction{}` struct**。
  # 持久化层(`load_state`)如实回放任何写过的行,可能带回非 struct 的 transaction
  # 值——跨版本残留行、字段缺失的旧行、或共享表里其它写入者(如 data_service store
  # 单测)留下的 plain map。这类值无法被 2PC 驱动(没有可用的 participants /
  # decision_version / timeout_at_ms),保留在活跃集只会让 deadline 调度 / sweep /
  # recovery watcher 在残缺字段上崩溃。
  #
  # 这里在 boot 把活跃集收敛为合法 struct:非 struct 的 transaction 值被丢出
  # `transactions`(连带丢掉它悬空的 begin_fingerprint),emit 观测。`decisions` /
  # `decision_index` 归档不动——它们足以回答幂等重放,且不参与 deadline / 驱动。
  defp sanitize_loaded_active_set(state) do
    {valid, dropped} =
      Enum.split_with(state.transactions, fn
        {_id, %BuildTransaction{}} -> true
        _ -> false
      end)

    if dropped == [] do
      state
    else
      dropped_ids = Enum.map(dropped, fn {id, _} -> id end)

      CliObserve.emit("voxel_transaction_coordinator_dropped_invalid_active_rows", fn ->
        %{count: length(dropped_ids), transaction_ids: inspect(dropped_ids)}
      end)

      %{
        state
        | transactions: Map.new(valid),
          begin_fingerprints: Map.drop(state.begin_fingerprints, dropped_ids)
      }
    end
  end

  defp run_load(nil), do: {:ok, %{}}

  defp run_load(load_fn) when is_function(load_fn, 0) do
    case load_fn.() do
      {:ok, payload} when is_map(payload) -> validate_persisted_payload(payload)
      {:error, _reason} = err -> err
      other -> {:error, {:unexpected_load_result, other}}
    end
  end

  defp validate_persisted_payload(payload) when is_map(payload) do
    expected_keys = [:transactions, :begin_fingerprints, :decisions, :decision_index]

    keys = Map.keys(payload)

    cond do
      keys == [] ->
        {:ok, %{}}

      Enum.any?(keys, fn key -> key not in expected_keys end) ->
        {:error, {:unexpected_keys, keys -- expected_keys}}

      Enum.any?(payload, fn {_key, value} -> not is_map(value) end) ->
        {:error, :unexpected_value_shape}

      true ->
        {:ok, payload}
    end
  end

  defp validate_persisted_payload(_other), do: {:error, :unexpected_payload_shape}
end
