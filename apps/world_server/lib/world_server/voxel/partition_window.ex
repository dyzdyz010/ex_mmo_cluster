defmodule WorldServer.Voxel.PartitionWindow do
  @moduledoc """
  Pure builder for read-only world partition interest windows.

  Near and halo radii are inclusive horizontal radii around the center chunk.
  Vertical radii clip the `z` axis independently so open-world scenes can avoid
  pulling irrelevant layers into the live sync budget. Defaults preserve the
  original cube semantics by using the horizontal radius as the vertical radius.
  The resulting `near_chunks` and `halo_chunks` are disjoint tier lists.
  """

  @type chunk_coord :: {integer(), integer(), integer()}
  @type tier :: :near | :halo

  @type route_entry :: %{
          chunk_coord: chunk_coord(),
          tier: tier(),
          status: :assigned | :region_without_lease | :missing,
          region_id: non_neg_integer() | nil,
          lease_id: non_neg_integer() | nil,
          lease: map() | nil,
          assigned_scene_node: node() | nil
        }

  @type region_summary :: %{
          region_id: non_neg_integer(),
          near_count: non_neg_integer(),
          halo_count: non_neg_integer(),
          lease_id: non_neg_integer() | nil,
          assigned_scene_node: node() | nil
        }

  @type t :: %{
          logical_scene_id: non_neg_integer(),
          center_chunk: chunk_coord(),
          near_radius: non_neg_integer(),
          halo_radius: non_neg_integer(),
          near_vertical_radius: non_neg_integer(),
          halo_vertical_radius: non_neg_integer(),
          near_chunks: [chunk_coord()],
          halo_chunks: [chunk_coord()],
          route_entries: [route_entry()],
          missing_chunks: [chunk_coord()],
          region_summaries: [region_summary()]
        }

  @doc """
  Builds one partition window and defaults all candidate chunks to `:missing`.
  """
  @spec build(non_neg_integer(), chunk_coord(), keyword()) :: t()
  def build(logical_scene_id, center_chunk, opts \\ []) do
    center_chunk = coord!(center_chunk)
    near_radius = validate_near_radius(Keyword.get(opts, :near_radius, 0))
    halo_radius = validate_halo_radius(Keyword.get(opts, :halo_radius, near_radius), near_radius)

    near_vertical_radius =
      validate_vertical_radius(
        Keyword.get(opts, :near_vertical_radius, near_radius),
        :near_vertical_radius
      )

    halo_vertical_radius =
      validate_halo_vertical_radius(
        Keyword.get(opts, :halo_vertical_radius, halo_radius),
        near_vertical_radius
      )

    near_chunks = interest_chunks(center_chunk, near_radius, near_vertical_radius)
    halo_chunks = halo_chunks(center_chunk, halo_radius, halo_vertical_radius, near_chunks)

    window = %{
      logical_scene_id: logical_scene_id,
      center_chunk: center_chunk,
      near_radius: near_radius,
      halo_radius: halo_radius,
      near_vertical_radius: near_vertical_radius,
      halo_vertical_radius: halo_vertical_radius,
      near_chunks: near_chunks,
      halo_chunks: halo_chunks,
      route_entries: [],
      missing_chunks: [],
      region_summaries: []
    }

    attach_routes(window, Keyword.get(opts, :routes, %{}))
  end

  @doc """
  Attaches route results to a previously built window without mutating geometry.
  """
  @spec attach_routes(t(), map() | list()) :: t()
  def attach_routes(window, routes) when is_map(window) do
    route_lookup = normalize_routes(routes)

    route_entries =
      Enum.map(window.near_chunks, &route_entry(&1, :near, route_lookup)) ++
        Enum.map(window.halo_chunks, &route_entry(&1, :halo, route_lookup))

    missing_chunks =
      for %{status: :missing, chunk_coord: chunk_coord} <- route_entries, do: chunk_coord

    region_summaries =
      route_entries
      |> Enum.reject(&is_nil(&1.region_id))
      |> Enum.group_by(& &1.region_id)
      |> Enum.map(fn {region_id, entries} ->
        anchor = List.first(entries)

        %{
          region_id: region_id,
          near_count: Enum.count(entries, &(&1.tier == :near)),
          halo_count: Enum.count(entries, &(&1.tier == :halo)),
          lease_id: anchor.lease_id,
          assigned_scene_node: anchor.assigned_scene_node
        }
      end)
      |> Enum.sort_by(& &1.region_id)

    %{
      window
      | route_entries: route_entries,
        missing_chunks: missing_chunks,
        region_summaries: region_summaries
    }
  end

  defp interest_chunks({center_x, center_y, center_z}, horizontal_radius, vertical_radius) do
    for x <- (center_x - horizontal_radius)..(center_x + horizontal_radius),
        y <- (center_y - horizontal_radius)..(center_y + horizontal_radius),
        z <- (center_z - vertical_radius)..(center_z + vertical_radius),
        horizontal_distance = horizontal_distance({center_x, center_y}, {x, y}),
        horizontal_distance <= horizontal_radius do
      {x, y, z}
    end
  end

  defp halo_chunks(center_chunk, halo_radius, halo_vertical_radius, near_chunks) do
    near_lookup = MapSet.new(near_chunks)

    center_chunk
    |> interest_chunks(halo_radius, halo_vertical_radius)
    |> Enum.reject(&MapSet.member?(near_lookup, &1))
  end

  defp horizontal_distance({left_x, left_y}, {right_x, right_y}) do
    max(abs(left_x - right_x), abs(left_y - right_y))
  end

  defp route_entry(chunk_coord, tier, route_lookup) do
    attrs = Map.get(route_lookup, chunk_coord, %{})
    status = route_status(attrs)

    %{
      chunk_coord: chunk_coord,
      tier: tier,
      status: status,
      region_id: route_region_id(status, attrs),
      lease_id: route_lease_id(status, attrs),
      lease: route_lease(status, attrs),
      assigned_scene_node: route_assigned_scene_node(status, attrs)
    }
  end

  defp route_status(attrs) do
    cond do
      Map.has_key?(attrs, :status) -> Map.fetch!(attrs, :status)
      is_nil(Map.get(attrs, :region_id)) -> :missing
      is_nil(Map.get(attrs, :lease_id)) -> :region_without_lease
      true -> :assigned
    end
  end

  defp route_region_id(:missing, _attrs), do: nil
  defp route_region_id(_status, attrs), do: Map.get(attrs, :region_id)

  defp route_lease_id(:missing, _attrs), do: nil
  defp route_lease_id(_status, attrs), do: Map.get(attrs, :lease_id)

  defp route_lease(:assigned, attrs), do: Map.get(attrs, :lease)
  defp route_lease(_status, _attrs), do: nil

  defp route_assigned_scene_node(:missing, _attrs), do: nil
  defp route_assigned_scene_node(_status, attrs), do: Map.get(attrs, :assigned_scene_node)

  defp normalize_routes(routes) when is_map(routes) do
    Map.new(routes, fn {chunk_coord, attrs} ->
      {coord!(chunk_coord), normalize_route_attrs(attrs)}
    end)
  end

  defp normalize_routes(routes) when is_list(routes) do
    Map.new(routes, fn attrs ->
      attrs = normalize_route_attrs(attrs)
      {coord!(Map.fetch!(attrs, :chunk_coord)), Map.delete(attrs, :chunk_coord)}
    end)
  end

  defp normalize_routes(other) do
    raise ArgumentError, "expected routes as map or list, got: #{inspect(other)}"
  end

  defp normalize_route_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_route_attrs(attrs) when is_list(attrs), do: Map.new(attrs)

  defp normalize_route_attrs(other) do
    raise ArgumentError, "expected route attrs as map or keyword list, got: #{inspect(other)}"
  end

  defp validate_near_radius(radius) when is_integer(radius) and radius >= 0, do: radius

  defp validate_near_radius(other) do
    raise ArgumentError, "near_radius must be a non-negative integer, got: #{inspect(other)}"
  end

  defp validate_halo_radius(radius, near_radius)
       when is_integer(radius) and radius >= near_radius,
       do: radius

  defp validate_halo_radius(radius, _near_radius) when not is_integer(radius) do
    raise ArgumentError, "halo_radius must be a non-negative integer, got: #{inspect(radius)}"
  end

  defp validate_halo_radius(radius, near_radius) do
    raise ArgumentError,
          "halo_radius must be greater than or equal to near_radius, got: #{inspect(radius)} < #{inspect(near_radius)}"
  end

  defp validate_vertical_radius(radius, _label) when is_integer(radius) and radius >= 0,
    do: radius

  defp validate_vertical_radius(radius, label) do
    raise ArgumentError,
          "#{label} must be a non-negative integer, got: #{inspect(radius)}"
  end

  defp validate_halo_vertical_radius(radius, near_vertical_radius)
       when is_integer(radius) and radius >= near_vertical_radius,
       do: radius

  defp validate_halo_vertical_radius(radius, _near_vertical_radius) when not is_integer(radius) do
    raise ArgumentError,
          "halo_vertical_radius must be a non-negative integer, got: #{inspect(radius)}"
  end

  defp validate_halo_vertical_radius(radius, near_vertical_radius) do
    raise ArgumentError,
          "halo_vertical_radius must be greater than or equal to near_vertical_radius, got: #{inspect(radius)} < #{inspect(near_vertical_radius)}"
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end
end
