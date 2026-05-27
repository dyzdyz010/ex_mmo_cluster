defmodule GateServer.ChatScope do
  @moduledoc """
  Derives authoritative chat delivery channels from Gate connection context.

  Clients may request a chat scope, but they do not supply partition authority.
  Region and local channels are resolved from the latest server-owned
  `partition_context` / `chat_context` kept on the Gate connection.
  """

  @type scope :: :world | :region | :local
  @type channel ::
          {:world, integer()}
          | {:region, integer(), integer()}
          | {:local, integer(), {integer(), integer(), integer()}, non_neg_integer()}
          | {:local, integer(), {integer(), integer(), integer()}, non_neg_integer(), [integer()]}

  @doc """
  Returns the concrete ChatServer channel for a requested client scope.

  The returned map is safe to put into observe logs and pass to
  `GateServer.ChatAdapter.publish/1`.
  """
  @spec derive(scope() | {:unknown, integer()} | term(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def derive(scope, source, opts \\ [])

  def derive(:world, source, _opts) when is_map(source) do
    logical_scene_id = logical_scene_id(source)

    {:ok,
     %{
       scope: :world,
       channel: {:world, logical_scene_id},
       logical_scene_id: logical_scene_id,
       server_derived?: true
     }}
  end

  def derive(:region, source, _opts) when is_map(source) do
    with logical_scene_id when is_integer(logical_scene_id) <- logical_scene_id(source),
         region_id when is_integer(region_id) <- field(source, :region_id) do
      {:ok,
       %{
         scope: :region,
         channel: {:region, logical_scene_id, region_id},
         logical_scene_id: logical_scene_id,
         region_id: region_id,
         server_derived?: true
       }}
    else
      _other -> {:error, :missing_chat_region}
    end
  end

  def derive(:local, source, opts) when is_map(source) do
    with logical_scene_id when is_integer(logical_scene_id) <- logical_scene_id(source),
         {_, _, _} = chunk_coord <- field(source, :chunk_coord) do
      radius = local_radius(opts)
      candidate_region_ids = candidate_region_ids(source, radius)

      target = %{
        scope: :local,
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord,
        local_radius: radius,
        server_derived?: true
      }

      if candidate_region_ids == [] do
        {:ok, Map.put(target, :channel, {:local, logical_scene_id, chunk_coord, radius})}
      else
        {:ok,
         target
         |> Map.put(:candidate_region_ids, candidate_region_ids)
         |> Map.put(:candidate_region_radius, candidate_region_radius(source))
         |> Map.put(
           :channel,
           {:local, logical_scene_id, chunk_coord, radius, candidate_region_ids}
         )}
      end
    else
      _other -> {:error, :missing_chat_chunk}
    end
  end

  def derive({:unknown, _value}, _source, _opts), do: {:error, :invalid_chat_scope}
  def derive(_scope, _source, _opts), do: {:error, :invalid_chat_scope}

  defp logical_scene_id(source) do
    case field(source, :logical_scene_id) do
      value when is_integer(value) -> value
      _other -> Application.get_env(:gate_server, :default_chat_logical_scene_id, 1)
    end
  end

  defp field(source, key) do
    source
    |> context_candidates()
    |> Enum.find_value(fn
      context when is_map(context) -> Map.get(context, key)
      _other -> nil
    end)
  end

  defp context_candidates(
         %{partition_context: partition_context, chat_context: chat_context} = source
       ) do
    [partition_context, chat_context, source]
  end

  defp context_candidates(%{partition_context: partition_context} = source) do
    [partition_context, source]
  end

  defp context_candidates(%{chat_context: chat_context} = source) do
    [chat_context, source]
  end

  defp context_candidates(source), do: [source]

  defp local_radius(opts) do
    opts
    |> Keyword.get(:local_radius, Application.get_env(:gate_server, :local_chat_radius, 1))
    |> normalize_local_radius()
  end

  defp normalize_local_radius(value) when is_integer(value) and value >= 0, do: value
  defp normalize_local_radius(_value), do: 1

  defp candidate_region_ids(source, local_radius) do
    region_ids =
      source
      |> field(:candidate_region_ids)
      |> normalize_candidate_region_ids()

    coverage_radius = candidate_region_radius(source)

    cond do
      region_ids == [] -> []
      is_integer(coverage_radius) and coverage_radius >= local_radius -> region_ids
      true -> []
    end
  end

  defp candidate_region_radius(source) do
    case field(source, :candidate_region_radius) do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end

  defp normalize_candidate_region_ids(region_ids) when is_list(region_ids) do
    region_ids
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_candidate_region_ids(_region_ids), do: []
end
