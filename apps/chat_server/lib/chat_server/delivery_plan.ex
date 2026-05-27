defmodule ChatServer.DeliveryPlan do
  @moduledoc """
  Pure delivery planner for MMO chat channels.

  The planner consumes session metadata and returns the recipients for a chat
  message. It owns no process state and does not talk to Gate, Scene, World, or
  DataService directly.
  """

  @type chunk_coord :: {integer(), integer(), integer()}
  @type channel ::
          {:world, integer()}
          | {:region, integer(), integer()}
          | {:local, integer(), chunk_coord(), non_neg_integer()}
          | {:local, integer(), chunk_coord(), non_neg_integer(), [integer()]}
          | {:system, :all | integer()}

  @doc "Builds a deterministic recipient plan for a chat channel."
  def plan(%{sessions: sessions, channel: channel}) when is_map(sessions) do
    normalized_channel = normalize_channel!(channel)

    recipients =
      sessions
      |> Enum.map(fn {cid, session} -> normalize_session(cid, session) end)
      |> Enum.filter(&eligible?(&1, normalized_channel))
      |> Enum.sort_by(& &1.cid)

    %{
      channel: normalized_channel,
      recipients: recipients,
      recipient_cids: Enum.map(recipients, & &1.cid),
      recipient_count: length(recipients),
      skipped_count: map_size(sessions) - length(recipients)
    }
  end

  @doc """
  Builds a recipient plan from precomputed presence indexes.

  `ChatServer.Runtime` uses this in the hot path so world, region, and local
  channel fan-out do not scan the full session table on every message.
  """
  def plan_indexed(%{sessions: sessions, presence_index: index, channel: channel})
      when is_map(sessions) and is_map(index) do
    normalized_channel = normalize_channel!(channel)

    recipients =
      index
      |> indexed_recipient_cids(sessions, normalized_channel)
      |> Enum.flat_map(fn cid ->
        case Map.fetch(sessions, cid) do
          {:ok, session} -> [normalize_session(cid, session)]
          :error -> []
        end
      end)
      |> Enum.filter(&eligible?(&1, normalized_channel))
      |> Enum.sort_by(& &1.cid)

    %{
      channel: normalized_channel,
      plan_source: :presence_index,
      recipients: recipients,
      recipient_cids: Enum.map(recipients, & &1.cid),
      recipient_count: length(recipients),
      skipped_count: map_size(sessions) - length(recipients)
    }
  end

  defp eligible?(session, {:world, logical_scene_id}) do
    session.logical_scene_id == logical_scene_id
  end

  defp eligible?(session, {:region, logical_scene_id, region_id}) do
    session.logical_scene_id == logical_scene_id and session.region_id == region_id
  end

  defp eligible?(session, {:local, logical_scene_id, center_chunk, radius}) do
    session.logical_scene_id == logical_scene_id and
      chunk_coord?(session.chunk_coord) and
      l_inf_distance(session.chunk_coord, center_chunk) <= radius
  end

  defp eligible?(
         session,
         {:local, logical_scene_id, center_chunk, radius, candidate_region_ids}
       ) do
    session.logical_scene_id == logical_scene_id and
      session.region_id in candidate_region_ids and
      chunk_coord?(session.chunk_coord) and
      l_inf_distance(session.chunk_coord, center_chunk) <= radius
  end

  defp eligible?(_session, {:system, :all}), do: true

  defp eligible?(session, {:system, logical_scene_id}),
    do: session.logical_scene_id == logical_scene_id

  defp indexed_recipient_cids(index, sessions, {:world, logical_scene_id}) do
    index_cids(index, :world, logical_scene_id, sessions)
  end

  defp indexed_recipient_cids(index, sessions, {:region, logical_scene_id, region_id}) do
    index_cids(index, :region, {logical_scene_id, region_id}, sessions)
  end

  defp indexed_recipient_cids(index, sessions, {:local, logical_scene_id, center_chunk, radius}) do
    center_chunk
    |> chunk_window(radius)
    |> Enum.flat_map(&index_cids(index, :local, {logical_scene_id, &1}, sessions))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp indexed_recipient_cids(
         index,
         sessions,
         {:local, logical_scene_id, _center_chunk, _radius, candidate_region_ids}
       ) do
    candidate_region_ids
    |> Enum.flat_map(&index_cids(index, :region, {logical_scene_id, &1}, sessions))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp indexed_recipient_cids(_index, sessions, {:system, :all}) do
    sessions |> Map.keys() |> Enum.sort()
  end

  defp indexed_recipient_cids(index, sessions, {:system, logical_scene_id}) do
    index_cids(index, :world, logical_scene_id, sessions)
  end

  defp index_cids(index, kind, key, _sessions) do
    index
    |> Map.get(kind, %{})
    |> Map.get(key, MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp normalize_channel!({:world, logical_scene_id}) when is_integer(logical_scene_id) do
    {:world, logical_scene_id}
  end

  defp normalize_channel!({:region, logical_scene_id, region_id})
       when is_integer(logical_scene_id) and is_integer(region_id) do
    {:region, logical_scene_id, region_id}
  end

  defp normalize_channel!({:local, logical_scene_id, center_chunk, radius})
       when is_integer(logical_scene_id) and is_integer(radius) and radius >= 0 do
    {:local, logical_scene_id, coord!(center_chunk), radius}
  end

  defp normalize_channel!({:local, logical_scene_id, center_chunk, radius, candidate_region_ids})
       when is_integer(logical_scene_id) and is_integer(radius) and radius >= 0 do
    {:local, logical_scene_id, coord!(center_chunk), radius,
     normalize_region_ids!(candidate_region_ids)}
  end

  defp normalize_channel!({:system, :all}), do: {:system, :all}

  defp normalize_channel!({:system, logical_scene_id}) when is_integer(logical_scene_id) do
    {:system, logical_scene_id}
  end

  defp normalize_channel!(channel) do
    raise ArgumentError, "unsupported chat channel: #{inspect(channel)}"
  end

  defp normalize_session(cid, session) when is_map(session) do
    %{
      cid: Map.get(session, :cid, cid),
      username: Map.get(session, :username, "anonymous"),
      connection_pid: Map.fetch!(session, :connection_pid),
      logical_scene_id: Map.get(session, :logical_scene_id, 1),
      region_id: Map.get(session, :region_id),
      chunk_coord: Map.get(session, :chunk_coord)
    }
  end

  defp l_inf_distance({ax, ay, az}, {bx, by, bz}) do
    [abs(ax - bx), abs(ay - by), abs(az - bz)] |> Enum.max()
  end

  defp chunk_window({cx, cy, cz}, radius) do
    for x <- (cx - radius)..(cx + radius),
        y <- (cy - radius)..(cy + radius),
        z <- (cz - radius)..(cz + radius) do
      {x, y, z}
    end
  end

  defp chunk_coord?({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: true
  defp chunk_coord?(_value), do: false

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp normalize_region_ids!(region_ids) when is_list(region_ids) do
    region_ids
    |> Enum.map(fn
      region_id when is_integer(region_id) ->
        region_id

      value ->
        raise ArgumentError, "candidate region id must be an integer, got: #{inspect(value)}"
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_region_ids!(value) do
    raise ArgumentError, "candidate region ids must be a list, got: #{inspect(value)}"
  end
end
