defmodule GateServer.Voxel.DeliveryEnvelope do
  @moduledoc """
  Validates Scene-to-Gate live voxel delivery envelopes.

  Scene remains the authority for chunk, field, and object state. Gate accepts a
  small metadata envelope at the transport boundary, validates the routing and
  budget fields once, and then schedules by metadata instead of re-decoding hot
  payloads.
  """

  @frame_kinds [
    :snapshot,
    :delta,
    :invalidate,
    :object_state_delta,
    :field_region_snapshot,
    :field_region_destroyed
  ]
  @tiers [:near, :halo]
  @stream_classes [
    :reliable_control,
    :voxel_snapshot,
    :voxel_delta,
    :field_state,
    :recovery,
    :event
  ]

  @doc """
  Normalizes a raw envelope map into scheduler-ready metadata.

  The normalized frame contains both `:byte_size` and `:bytes` so observe logs
  can report the contract field while the scheduler can keep its existing queue
  accounting.
  """
  def normalize(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = mapify(attrs)
    frame_kind = get(attrs, :frame_kind)
    payload = get(attrs, :payload)
    expected_byte_size = get(attrs, :byte_size)

    with {:ok, frame_kind} <- normalize_frame_kind(frame_kind),
         {:ok, payload} <- normalize_payload(frame_kind, payload),
         {:ok, payload_bytes} <- validate_byte_size(frame_kind, expected_byte_size, payload),
         {:ok, common} <- normalize_common(frame_kind, attrs, payload, payload_bytes),
         {:ok, frame} <- normalize_frame(frame_kind, attrs, common) do
      {:ok, frame}
    end
  end

  def normalize(_attrs) do
    invalid(nil, :invalid_envelope_type)
  end

  defp normalize_common(frame_kind, attrs, payload, payload_bytes) do
    with {:ok, logical_scene_id} <-
           required_non_negative_integer(frame_kind, attrs, :logical_scene_id),
         {:ok, tier} <- required_enum(frame_kind, attrs, :tier, @tiers),
         {:ok, stream_class} <- required_enum(frame_kind, attrs, :stream_class, @stream_classes),
         :ok <- validate_stream_class(frame_kind, stream_class),
         {:ok, server_version} <-
           required_non_negative_integer(frame_kind, attrs, :server_version),
         {:ok, lease_id} <- required_non_negative_integer(frame_kind, attrs, :lease_id),
         {:ok, owner_epoch} <- required_non_negative_integer(frame_kind, attrs, :owner_epoch) do
      {:ok,
       %{
         frame_kind: frame_kind,
         logical_scene_id: logical_scene_id,
         tier: tier,
         stream_class: stream_class,
         byte_size: payload_bytes,
         bytes: payload_bytes,
         server_version: server_version,
         lease_id: lease_id,
         owner_epoch: owner_epoch,
         payload: payload,
         metadata_source: :envelope,
         payload_decode_used: false
       }}
    end
  end

  defp normalize_frame(:snapshot = frame_kind, attrs, common) do
    with {:ok, chunk_coord} <- required_coord(frame_kind, attrs, :chunk_coord) do
      {:ok,
       common
       |> Map.put(:chunk_coord, chunk_coord)
       |> Map.put(:chunk_version, common.server_version)}
    end
  end

  defp normalize_frame(:delta = frame_kind, attrs, common) do
    with {:ok, chunk_coord} <- required_coord(frame_kind, attrs, :chunk_coord),
         {:ok, base_chunk_version} <-
           required_non_negative_integer(frame_kind, attrs, :base_server_version,
             fallback_key: :base_chunk_version
           ) do
      {:ok,
       common
       |> Map.put(:chunk_coord, chunk_coord)
       |> Map.put(:base_chunk_version, base_chunk_version)
       |> Map.put(:chunk_version, common.server_version)}
    end
  end

  defp normalize_frame(:invalidate = frame_kind, attrs, common) do
    with {:ok, chunk_coord} <- required_coord(frame_kind, attrs, :chunk_coord) do
      {:ok,
       common
       |> Map.put(:chunk_coord, chunk_coord)
       |> maybe_put(:reason, get(attrs, :reason))
       |> maybe_put(:reason_name, get(attrs, :reason_name))}
    end
  end

  defp normalize_frame(:object_state_delta = frame_kind, attrs, common) do
    with {:ok, object_id} <- required_non_negative_integer(frame_kind, attrs, :object_id),
         {:ok, object_version} <-
           required_non_negative_integer(frame_kind, attrs, :object_version),
         {:ok, affected_chunks} <- required_coord_list(frame_kind, attrs, :affected_chunks) do
      {:ok,
       common
       |> Map.put(:object_id, object_id)
       |> Map.put(:object_version, object_version)
       |> Map.put(:affected_chunks, affected_chunks)}
    end
  end

  defp normalize_frame(:field_region_snapshot = frame_kind, attrs, common) do
    with {:ok, chunk_coord} <- required_coord(frame_kind, attrs, :chunk_coord),
         {:ok, region_id} <- required_non_negative_integer(frame_kind, attrs, :region_id),
         {:ok, tick_count} <- required_non_negative_integer(frame_kind, attrs, :tick_count) do
      {:ok,
       common
       |> Map.put(:chunk_coord, chunk_coord)
       |> Map.put(:region_id, region_id)
       |> Map.put(:tick_count, tick_count)}
    end
  end

  defp normalize_frame(:field_region_destroyed = frame_kind, attrs, common) do
    with {:ok, chunk_coord} <- required_coord(frame_kind, attrs, :chunk_coord),
         {:ok, region_id} <- required_non_negative_integer(frame_kind, attrs, :region_id),
         {:ok, destroy_reason} <- required_value(frame_kind, attrs, :destroy_reason) do
      {:ok,
       common
       |> Map.put(:chunk_coord, chunk_coord)
       |> Map.put(:region_id, region_id)
       |> Map.put(:destroy_reason, destroy_reason)}
    end
  end

  defp normalize_frame(frame_kind, _attrs, _common),
    do: invalid(frame_kind, :unsupported_frame_kind)

  defp normalize_frame_kind(value) when value in @frame_kinds, do: {:ok, value}

  defp normalize_frame_kind(value) when is_binary(value) do
    case value do
      "snapshot" -> {:ok, :snapshot}
      "delta" -> {:ok, :delta}
      "invalidate" -> {:ok, :invalidate}
      "object_state_delta" -> {:ok, :object_state_delta}
      "field_region_snapshot" -> {:ok, :field_region_snapshot}
      "field_region_destroyed" -> {:ok, :field_region_destroyed}
      _other -> invalid(value, :invalid_frame_kind)
    end
  end

  defp normalize_frame_kind(value), do: invalid(value, :invalid_frame_kind)

  defp normalize_payload(_frame_kind, payload) when is_binary(payload), do: {:ok, payload}

  defp normalize_payload(frame_kind, _payload), do: invalid(frame_kind, :missing_payload)

  defp validate_byte_size(frame_kind, expected, payload)
       when is_integer(expected) and expected >= 0 do
    actual = byte_size(payload)

    if expected == actual do
      {:ok, actual}
    else
      invalid(frame_kind, :byte_size_mismatch, %{
        expected_byte_size: expected,
        actual_byte_size: actual
      })
    end
  end

  defp validate_byte_size(frame_kind, _expected, _payload),
    do: invalid(frame_kind, :invalid_byte_size)

  defp required_non_negative_integer(frame_kind, attrs, key, opts \\ []) do
    value = get(attrs, key)

    value =
      if is_nil(value) and Keyword.has_key?(opts, :fallback_key) do
        get(attrs, Keyword.fetch!(opts, :fallback_key))
      else
        value
      end

    case value do
      integer when is_integer(integer) and integer >= 0 ->
        {:ok, integer}

      nil ->
        invalid(frame_kind, missing_reason(key))

      _other ->
        invalid(frame_kind, invalid_reason(key))
    end
  end

  defp required_coord(frame_kind, attrs, key) do
    case coord(get(attrs, key)) do
      {:ok, coord} -> {:ok, coord}
      :missing -> invalid(frame_kind, missing_reason(key))
      :invalid -> invalid(frame_kind, invalid_reason(key))
    end
  end

  defp required_coord_list(frame_kind, attrs, key) do
    case get(attrs, key) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
          case coord(value) do
            {:ok, coord} -> {:cont, {:ok, [coord | acc]}}
            _other -> {:halt, :invalid}
          end
        end)
        |> case do
          {:ok, coords} -> {:ok, Enum.reverse(coords)}
          :invalid -> invalid(frame_kind, invalid_reason(key))
        end

      nil ->
        invalid(frame_kind, missing_reason(key))

      _other ->
        invalid(frame_kind, invalid_reason(key))
    end
  end

  defp required_enum(frame_kind, attrs, key, allowed_values) do
    value = get(attrs, key)

    cond do
      value in allowed_values -> {:ok, value}
      is_nil(value) -> invalid(frame_kind, missing_reason(key))
      true -> invalid(frame_kind, invalid_reason(key))
    end
  end

  defp required_value(frame_kind, attrs, key) do
    case get(attrs, key) do
      nil -> invalid(frame_kind, missing_reason(key))
      value -> {:ok, value}
    end
  end

  defp validate_stream_class(frame_kind, stream_class) do
    allowed =
      case frame_kind do
        :snapshot -> [:voxel_snapshot, :recovery]
        :delta -> [:voxel_delta, :recovery]
        :invalidate -> [:reliable_control]
        :object_state_delta -> [:event]
        :field_region_snapshot -> [:field_state]
        :field_region_destroyed -> [:reliable_control]
      end

    if stream_class in allowed do
      :ok
    else
      invalid(frame_kind, :stream_class_mismatch, %{
        stream_class: stream_class,
        expected_stream_classes: allowed
      })
    end
  end

  defp coord(nil), do: :missing

  defp coord({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {:ok, {x, y, z}}

  defp coord([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {:ok, {x, y, z}}

  defp coord(_value), do: :invalid

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp missing_reason(key), do: :"missing_#{key}"
  defp invalid_reason(key), do: :"invalid_#{key}"

  defp invalid(frame_kind, reason, attrs \\ %{}) do
    {:error,
     Map.merge(
       %{
         frame_kind: frame_kind,
         reason: reason,
         metadata_source: :envelope,
         payload_decode_used: false
       },
       attrs
     )}
  end

  defp mapify(attrs) when is_map(attrs), do: attrs
  defp mapify(attrs) when is_list(attrs), do: Map.new(attrs)

  defp get(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
