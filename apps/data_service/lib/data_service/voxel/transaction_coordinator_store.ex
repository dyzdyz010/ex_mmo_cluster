defmodule DataService.Voxel.TransactionCoordinatorStore do
  @moduledoc """
  Durable backing store for `WorldServer.Voxel.TransactionCoordinator`.

  阶段4 / world-2pc-4:**行级增量持久化**。每笔事务一行
  (`voxel_transaction_coordinator_rows`,主键 `transaction_id`),不再把整个
  协调者状态 `term_to_binary` 成单行全量历史 blob。

  - `persist_rows/3` 只 upsert **变更过的事务行** + 删除 **被裁剪/归档掉的行**,
    用一个 `insert_all` + 一个 `delete_all` 完成,写代价随单回合变更量(而非
    历史总量)线性。
  - `load_state/1` 扫全表把每行重建回协调者的四张 map
    (`transactions` / `begin_fingerprints` / `decisions` / `decision_index`),
    返回与旧单行 snapshot 完全相同的 in-memory 形状,协调者 `init` 无需感知
    存储从单行 blob 切到了多行。

  ## 行 payload 形态

  每行的 `payload` 是 `:erlang.term_to_binary/1` 编码的 map:

      %{
        transaction: %BuildTransaction{} | nil,   # 活跃事务带完整 struct;
                                                   # 终态裁剪后为 nil(只剩归档)
        begin_fingerprint: map() | nil,            # 同上
        decision_index: map() | nil                # 该事务最新决策归档记录
      }

  反序列化用 `:erlang.binary_to_term(_, [:safe])`,坏行被跳过并 emit
  `voxel_transaction_coordinator_row_decode_failed`,不让单行损坏拖垮整个
  协调者 hydrate(对齐 `SceneNodeRegistryStore` 的"坏行不静默当权威、也不
  crash"纪律)。

  `decisions` map 的恢复:协调者只把**有界**的终态决策窗口和活跃事务的决策行
  存为 `decision_index`;`load_state` 用每行的 `decision_index`(若存在)重建
  `{transaction_id, decision_version} => decision_record` 的 `decisions` map,
  幂等重放在 in-flight 重启后仍命中。
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias DataService.Schema.VoxelTransactionCoordinatorRow

  @doc """
  Persists a batch of changed transaction rows and deletes archived ids.

  - `changed_rows` — list of `{transaction_id, row_map}` where `row_map` is
    `%{transaction: _, begin_fingerprint: _, decision_index: _}`. Upserted in a
    single `insert_all` with `on_conflict: :replace_all`.
  - `deleted_ids` — list of `transaction_id` whose rows should be deleted (a
    transaction that was fully forgotten — currently never used because terminal
    transactions keep a lightweight archived row; the parameter exists so the
    coordinator can prune the historical window without a schema change).

  Atomicity: upsert and delete each run in one statement. They are not wrapped
  in a single transaction because the coordinator only ever deletes a
  transaction id it is not simultaneously upserting (the dirty/deleted sets are
  disjoint by construction), so there is no torn-write window between the two.
  """
  @spec persist_rows(Ecto.Repo.t(), [{term(), map()}], [term()]) :: :ok | {:error, term()}
  def persist_rows(repo, changed_rows, deleted_ids)
      when is_list(changed_rows) and is_list(deleted_ids) do
    with :ok <- upsert_changed(repo, changed_rows),
         :ok <- delete_archived(repo, deleted_ids) do
      :ok
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  defp upsert_changed(_repo, []), do: :ok

  defp upsert_changed(repo, changed_rows) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(changed_rows, fn {transaction_id, row_map} ->
        %{
          transaction_id: encode_id(transaction_id),
          payload: :erlang.term_to_binary(row_map),
          inserted_at: now,
          updated_at: now
        }
      end)

    case repo.insert_all(
           VoxelTransactionCoordinatorRow,
           entries,
           on_conflict: {:replace, [:payload, :updated_at]},
           conflict_target: :transaction_id
         ) do
      {count, _} when count >= 0 -> :ok
      _other -> {:error, :persist_failed}
    end
  end

  defp delete_archived(_repo, []), do: :ok

  defp delete_archived(repo, deleted_ids) do
    encoded = Enum.map(deleted_ids, &encode_id/1)

    repo.delete_all(
      from(r in VoxelTransactionCoordinatorRow, where: r.transaction_id in ^encoded)
    )

    :ok
  end

  @doc """
  Loads the persisted coordinator state by reconstructing the four maps from
  every row.

  Returns `{:ok, %{}}` on an empty table so a fresh deployment starts with the
  in-memory defaults. Individual corrupt rows are skipped (with an observe
  event) rather than failing the entire load.
  """
  @spec load_state(Ecto.Repo.t()) :: {:ok, map()} | {:error, term()}
  def load_state(repo) do
    rows = repo.all(VoxelTransactionCoordinatorRow)

    state =
      Enum.reduce(
        rows,
        %{transactions: %{}, begin_fingerprints: %{}, decisions: %{}, decision_index: %{}},
        fn row, acc -> merge_row(acc, row) end
      )

    if state == %{transactions: %{}, begin_fingerprints: %{}, decisions: %{}, decision_index: %{}} do
      {:ok, %{}}
    else
      {:ok, state}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  defp merge_row(acc, %VoxelTransactionCoordinatorRow{transaction_id: encoded, payload: payload})
       when is_binary(payload) do
    with {:ok, transaction_id} <- decode_id(encoded),
         {:ok, row_map} <- decode_payload(payload) do
      apply_row(acc, transaction_id, row_map)
    else
      {:error, reason} ->
        emit_row_decode_failed(encoded, reason)
        acc
    end
  end

  defp merge_row(acc, %VoxelTransactionCoordinatorRow{transaction_id: encoded}) do
    emit_row_decode_failed(encoded, :unexpected_row_shape)
    acc
  end

  defp apply_row(acc, transaction_id, row_map) do
    acc
    |> maybe_put(:transactions, transaction_id, Map.get(row_map, :transaction))
    |> maybe_put(:begin_fingerprints, transaction_id, Map.get(row_map, :begin_fingerprint))
    |> maybe_put_decision(transaction_id, Map.get(row_map, :decision_index))
  end

  defp maybe_put(acc, _map_key, _transaction_id, nil), do: acc

  defp maybe_put(acc, map_key, transaction_id, value) do
    update_in(acc[map_key], &Map.put(&1, transaction_id, value))
  end

  # decision_index 行同时重建 `decision_index` 和 `decisions`
  # (`{transaction_id, decision_version} => record`)。
  defp maybe_put_decision(acc, _transaction_id, nil), do: acc

  defp maybe_put_decision(acc, transaction_id, %{decision_version: dv} = record) do
    acc
    |> update_in([:decision_index], &Map.put(&1, transaction_id, record))
    |> update_in([:decisions], &Map.put(&1, {transaction_id, dv}, record))
  end

  defp maybe_put_decision(acc, _transaction_id, _record), do: acc

  @doc """
  Returns a 2-arity persist function bound to `repo` for the coordinator's
  `:persist_rows_fn` opt.
  """
  @spec persist_rows_fn(Ecto.Repo.t()) :: ([{term(), map()}], [term()] -> :ok | {:error, term()})
  def persist_rows_fn(repo) do
    fn changed_rows, deleted_ids -> persist_rows(repo, changed_rows, deleted_ids) end
  end

  @doc "Returns a 0-arity load function bound to `repo` for the coordinator's `:load_fn` opt."
  @spec load_fn(Ecto.Repo.t()) :: (-> {:ok, map()} | {:error, term()})
  def load_fn(repo), do: fn -> load_state(repo) end

  # transaction_id 可能是 binary 或 `{:voxel_transaction, integer}` tuple
  # (unique_transaction_id 生成)。统一 term_to_binary 成行主键的稳定字节串。
  defp encode_id(transaction_id), do: :erlang.term_to_binary(transaction_id)

  defp decode_id(encoded) when is_binary(encoded) do
    {:ok, :erlang.binary_to_term(encoded, [:safe])}
  rescue
    _exception in [ArgumentError] -> {:error, :invalid_transaction_id}
  end

  defp decode_payload(payload) when is_binary(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      term when is_map(term) -> {:ok, term}
      _other -> {:error, :unexpected_payload_shape}
    end
  rescue
    _exception in [ArgumentError] -> {:error, :invalid_payload}
  end

  defp emit_row_decode_failed(encoded, reason) do
    Logger.warning(
      "voxel_transaction_coordinator_row_decode_failed " <>
        "transaction_id_bytes=#{byte_size(encoded)} reason=#{inspect(reason)}"
    )
  rescue
    _ -> :ok
  end
end
