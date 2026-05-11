defmodule GateServer.Voxel.PrefabLocalTransaction do
  @moduledoc """
  Scene-local prefab transaction runner for same-owner multi-chunk placements.

  World still decides which region and lease owns each chunk before this module
  is used. This runner only handles the hot-path case where Gate has already
  proven every prefab participant resolves to the same Scene chunk-directory
  owner, so a full World `TransactionCoordinator` round trip would add latency
  without changing the write authority.
  """

  alias SceneServer.Voxel.BuildTransactionApplier

  @doc """
  Prepares and commits all prefab participants through their local Scene owner.

  `chunk_directory_ref_fun` receives each Gate participant and returns the
  concrete `ChunkDirectory` GenServer ref to use for that participant. On a
  prepare failure, participants prepared by this call are aborted before the
  error is returned.
  """
  def execute(participants, transaction_id, logical_scene_id, chunk_directory_ref_fun)
      when is_list(participants) and is_binary(transaction_id) and
             is_integer(logical_scene_id) and is_function(chunk_directory_ref_fun, 1) do
    case prepare_participants(
           participants,
           transaction_id,
           logical_scene_id,
           chunk_directory_ref_fun
         ) do
      {:ok, prepare_results} ->
        commit_participants(
          participants,
          transaction_id,
          logical_scene_id,
          chunk_directory_ref_fun,
          prepare_results
        )

      {:error, reason, prepare_results} ->
        abort_prepared(
          participants,
          transaction_id,
          logical_scene_id,
          chunk_directory_ref_fun,
          prepare_results
        )

        {:error, %{reason: reason, prepare_results: prepare_results, participant_results: []}}
    end
  end

  defp prepare_participants(
         participants,
         transaction_id,
         logical_scene_id,
         chunk_directory_ref_fun
       ) do
    Enum.reduce_while(participants, {:ok, []}, fn participant, {:ok, acc} ->
      transaction_participant = transaction_participant(participant)

      result =
        BuildTransactionApplier.prepare(
          transaction_participant,
          transaction_id,
          participant.intents_by_chunk,
          chunk_directory: chunk_directory_ref_fun.(participant),
          logical_scene_id: logical_scene_id
        )

      case result do
        {:ok, summary} ->
          {:cont, {:ok, [{transaction_participant, {:ok, summary}} | acc]}}

        {:error, reason} ->
          results = Enum.reverse([{transaction_participant, {:error, reason}} | acc])
          {:halt, {:error, reason, results}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason, _results} = error -> error
    end
  end

  defp commit_participants(
         participants,
         transaction_id,
         logical_scene_id,
         chunk_directory_ref_fun,
         prepare_results
       ) do
    transaction_participants = Enum.map(participants, &transaction_participant/1)

    participant_results =
      Enum.zip(participants, transaction_participants)
      |> Enum.map(fn {participant, transaction_participant} ->
        result =
          BuildTransactionApplier.commit(
            transaction_participant,
            transaction_id,
            chunk_directory: chunk_directory_ref_fun.(participant),
            logical_scene_id: logical_scene_id
          )

        {transaction_participant, result}
      end)

    case Enum.find(participant_results, fn {_participant, result} ->
           match?({:error, _}, result)
         end) do
      nil ->
        {:ok, %{participant_results: participant_results, prepare_results: prepare_results}}

      {_participant, {:error, reason}} ->
        {:error,
         %{
           reason: reason,
           participant_results: participant_results,
           prepare_results: prepare_results
         }}
    end
  end

  defp abort_prepared(
         participants,
         transaction_id,
         logical_scene_id,
         chunk_directory_ref_fun,
         prepare_results
       ) do
    participants_by_key =
      Map.new(participants, fn participant -> {participant_key(participant), participant} end)

    Enum.each(prepare_results, fn
      {transaction_participant, {:ok, _summary}} ->
        BuildTransactionApplier.abort(
          transaction_participant,
          transaction_id,
          chunk_directory:
            transaction_participant
            |> participant_key()
            |> then(&Map.fetch!(participants_by_key, &1))
            |> chunk_directory_ref_fun.(),
          logical_scene_id: logical_scene_id
        )

      _other ->
        :ok
    end)
  end

  defp transaction_participant(%{
         participant_key: participant_key,
         lease: lease,
         assigned_scene_node: assigned_scene_node,
         chunk_coords: chunk_coords,
         chunk_owners: chunk_owners
       }) do
    %{
      participant_key: participant_key,
      region_id: lease.region_id,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch,
      assigned_scene_node: assigned_scene_node,
      affected_chunks: chunk_coords,
      chunk_owners: chunk_owners
    }
  end

  defp participant_key(%{participant_key: key}), do: key
end
