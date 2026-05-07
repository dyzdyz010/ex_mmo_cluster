defmodule WorldServer.Voxel.TransactionCoordinator do
  @moduledoc """
  Coordinator for recoverable voxel build transactions.

  The coordinator owns the world-side transaction state machine. Scene
  processes remain participants: they execute prepare and commit/abort work,
  while this module records the durable intent, participant acknowledgements,
  and the single world decision for each `{transaction_id, decision_version}`
  pair.

  ## Durable persistence

  Persistence is injected via the `:persist_fn` (1-arity) and `:load_fn`
  (0-arity) start options. Production wiring uses
  `DataService.Voxel.TransactionCoordinatorStore.persist_fn/1` /
  `load_fn/1` so coordinator state survives node restart through Postgres.
  When neither option is supplied the coordinator runs purely in memory
  (used by isolated unit tests that do not need persistence).
  """

  use GenServer

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionParticipant

  @default_timeout_ms :timer.seconds(30)
  @prepare_success_statuses [:prepared, :ok]
  @prepare_failure_statuses [:failed, :rejected, :error, :aborted]
  @abortable_states [:preparing, :prepared, :aborting]

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

  The acknowledgement must include `:region_id`, `:lease_id`, and `:status`.
  Accepted statuses are `:prepared`/`:ok` for success and
  `:failed`/`:rejected`/`:error`/`:aborted` for failure.
  """
  def prepare_ack(transaction_id, ack) when is_map(ack) or is_list(ack) do
    prepare_ack(__MODULE__, transaction_id, ack)
  end

  @doc """
  Records a participant prepare acknowledgement against an explicit coordinator.

  The server-explicit form keeps the same `transaction_id` matching rules as the
  default-server form, but directs the call to the supplied GenServer. The ack is
  matched by `{region_id, lease_id}` so stale or unknown participants can be
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

  @doc "Returns a structured snapshot for CLI/debug inspection."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    persist_fn = Keyword.get(opts, :persist_fn)
    load_fn = Keyword.get(opts, :load_fn)

    base = %{
      transactions: %{},
      begin_fingerprints: %{},
      decisions: %{},
      decision_index: %{},
      persist_fn: persist_fn
    }

    case run_load(load_fn) do
      {:ok, restored} ->
        {:ok, Map.merge(base, restored)}

      {:error, reason} ->
        CliObserve.emit("voxel_transaction_coordinator_persist_load_failed", fn ->
          %{reason: inspect(reason)}
        end)

        {:ok, base}
    end
  end

  @impl true
  def handle_call(message, from, state) do
    case do_handle_call(message, from, state) do
      {:reply, _reply, ^state} = ret ->
        ret

      {:reply, reply, next_state} ->
        case maybe_persist_state(next_state) do
          :ok ->
            {:reply, reply, next_state}

          {:error, reason} ->
            CliObserve.emit("voxel_transaction_coordinator_persist_failed", fn ->
              %{reason: inspect(reason)}
            end)

            {:reply, reply, next_state}
        end
    end
  end

  defp do_handle_call({:begin_transaction, attrs}, _from, state) do
    case build_transaction(attrs) do
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
      next_state = put_in(state.transactions[transaction_id], next_transaction)

      if next_transaction != transaction do
        emit_prepare_ack(next_transaction, normalized_ack)
      end

      {:reply, {:ok, next_transaction}, next_state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_handle_call({:decision, transaction_id, decision_version, decision}, _from, state) do
    with {:ok, decision_version} <- normalize_decision_version(decision_version),
         {:ok, transaction} <- fetch_transaction(state, transaction_id),
         :ok <- validate_decision_version(transaction, decision_version),
         :new <- decision_replay(state, transaction_id, decision_version, decision),
         {:ok, next_transaction} <- apply_decision(transaction, decision) do
      next_state = record_decision(state, next_transaction, decision, decision_version)
      emit_decision(next_transaction, decision)

      {:reply, {:ok, next_transaction}, next_state}
    else
      {:replay, transaction} ->
        {:reply, {:ok, transaction}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  defp put_new_transaction(state, transaction, fingerprint) do
    transaction_id = transaction.transaction_id

    case Map.fetch(state.transactions, transaction_id) do
      :error ->
        next_state =
          state
          |> put_in([:transactions, transaction_id], transaction)
          |> put_in([:begin_fingerprints, transaction_id], fingerprint)

        emit_begin(transaction)
        {{:ok, transaction}, next_state}

      {:ok, existing} ->
        cond do
          state.begin_fingerprints[transaction_id] == fingerprint ->
            {{:ok, existing}, state}

          true ->
            {{:error, :transaction_conflict}, state}
        end
    end
  end

  defp apply_prepare_ack(%BuildTransaction{state: state} = transaction, _ack)
       when state in [:committed, :aborted] do
    {:ok, transaction}
  end

  defp apply_prepare_ack(transaction, ack) do
    participant_key = {ack.region_id, ack.lease_id}

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

  defp apply_decision(%BuildTransaction{state: :prepared} = transaction, :commit) do
    {:ok,
     %{
       transaction
       | state: :committed,
         participants: mark_commit_status(transaction.participants, :committed)
     }}
  end

  defp apply_decision(%BuildTransaction{state: state}, :commit)
       when state in [:preparing, :aborting] do
    {:error, :not_prepared}
  end

  defp apply_decision(%BuildTransaction{state: :aborted}, :commit) do
    {:error, {:already_decided, :abort}}
  end

  defp apply_decision(%BuildTransaction{state: :committed}, :commit) do
    {:error, {:already_decided, :commit}}
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

  defp apply_decision(%BuildTransaction{state: :committed}, :abort) do
    {:error, {:already_decided, :commit}}
  end

  defp apply_decision(%BuildTransaction{state: :aborted}, :abort) do
    {:error, {:already_decided, :abort}}
  end

  defp decision_replay(state, transaction_id, decision_version, decision) do
    case Map.fetch(state.decisions, {transaction_id, decision_version}) do
      {:ok, %{decision: ^decision}} ->
        {:replay, Map.fetch!(state.transactions, transaction_id)}

      {:ok, %{decision: other_decision}} ->
        {:error, {:decision_conflict, other_decision}}

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
    |> put_in([:decision_index, transaction.transaction_id], decision_record)
  end

  defp validate_decision_version(transaction, decision_version) do
    if transaction.decision_version == decision_version do
      :ok
    else
      {:error, {:decision_version_mismatch, transaction.decision_version}}
    end
  end

  defp build_transaction(attrs) do
    attrs = attrs_map(attrs)

    with {:ok, participants} <- fetch_participants(attrs),
         {:ok, decision_version} <- normalize_decision_version(value(attrs, :decision_version, 1)) do
      transaction = %BuildTransaction{
        transaction_id: value(attrs, :transaction_id, unique_transaction_id()),
        logical_scene_id: value(attrs, :logical_scene_id),
        parcel_id: value(attrs, :parcel_id),
        reservation_id: value(attrs, :reservation_id),
        participants: participants,
        intent_hash: value(attrs, :intent_hash, default_intent_hash(attrs, participants)),
        decision_version: decision_version,
        timeout_at_ms: value(attrs, :timeout_at_ms, now_ms() + @default_timeout_ms),
        state: :preparing
      }

      {:ok, transaction, begin_fingerprint(transaction)}
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
    {:ok,
     %{
       participant
       | prepare_status: :pending,
         commit_status: :pending,
         last_ack_ms: 0,
         affected_chunks: Enum.sort(participant.affected_chunks || [])
     }}
  end

  defp normalize_participant(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs_map(attrs)

    with {:ok, region_id} <- required_value(attrs, :region_id),
         {:ok, lease_id} <- required_value(attrs, :lease_id),
         {:ok, owner_scene_instance_ref} <- required_value(attrs, :owner_scene_instance_ref),
         {:ok, owner_epoch} <- required_value(attrs, :owner_epoch),
         {:ok, affected_chunks} <- required_value(attrs, :affected_chunks) do
      {:ok,
       %TransactionParticipant{
         region_id: region_id,
         lease_id: lease_id,
         owner_scene_instance_ref: owner_scene_instance_ref,
         owner_epoch: owner_epoch,
         affected_chunks: Enum.sort(affected_chunks),
         prepare_status: :pending,
         commit_status: :pending,
         last_ack_ms: 0
       }}
    end
  end

  defp normalize_participant(_attrs), do: {:error, :invalid_participant}

  defp normalize_prepare_ack(ack) do
    ack = attrs_map(ack)

    with {:ok, region_id} <- required_value(ack, :region_id),
         {:ok, lease_id} <- required_value(ack, :lease_id),
         {:ok, status} <- required_value(ack, :status),
         {:ok, prepare_status} <- normalize_prepare_status(status) do
      {:ok,
       %{
         region_id: region_id,
         lease_id: lease_id,
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
      region_id: participant.region_id,
      lease_id: participant.lease_id,
      owner_scene_instance_ref: participant.owner_scene_instance_ref,
      owner_epoch: participant.owner_epoch,
      affected_chunks: participant.affected_chunks
    }
  end

  defp participant_key(participant), do: {participant.region_id, participant.lease_id}

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
      transaction_count: map_size(state.transactions)
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

  defp unique_transaction_id do
    {:voxel_transaction, System.unique_integer([:positive, :monotonic])}
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp maybe_persist_state(%{persist_fn: nil}), do: :ok

  defp maybe_persist_state(%{persist_fn: persist_fn} = state) when is_function(persist_fn, 1) do
    payload = Map.take(state, [:transactions, :begin_fingerprints, :decisions, :decision_index])
    persist_fn.(payload)
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
