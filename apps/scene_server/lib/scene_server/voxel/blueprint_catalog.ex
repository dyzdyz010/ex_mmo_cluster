defmodule SceneServer.Voxel.BlueprintCatalog do
  @moduledoc """
  Server-side catalog of v1 hardcoded voxel prefab blueprints.

  Blueprint identifiers and their cell layouts are deliberately frozen for v1 so
  that clients (web + bevy) and server agree on the placeholder set without a
  data-driven asset pipeline. Each blueprint resolves to a fixed list of macro-
  cell offsets relative to the placement anchor and a single `material_id` used
  to fill every cell in the prefab.

  Out of scope for v1:

    - rotation (callers should pass the raw rotation byte through; this module
      ignores it)
    - microgrid / refined-cell prefabs
    - parcel build epoch / blueprint version negotiation (always treat
      `blueprint_version` 1 as canonical)

  The catalog is intentionally implemented as pure data + pure functions so it
  can be exercised by unit tests without spinning up the runtime supervision
  tree.
  """

  @typedoc "Local macro-cell offset relative to the prefab anchor, in macro units."
  @type cell_offset :: {integer(), integer(), integer()}

  @typedoc """
  v1 blueprint definition.

  `cells` is the list of macro-cell offsets that should be turned into solid
  blocks. `material_id` is the fixed normal-block material applied to every
  cell. `version` matches the blueprint version negotiated on the wire.
  """
  @type blueprint :: %{
          id: pos_integer(),
          name: String.t(),
          version: pos_integer(),
          material_id: 0..0xFFFF,
          cells: [cell_offset()]
        }

  @blueprints %{
    1 => %{
      id: 1,
      name: "builtin_pillar_3",
      version: 1,
      material_id: 1,
      cells: [{0, 0, 0}, {0, 0, 1}, {0, 0, 2}]
    },
    2 => %{
      id: 2,
      name: "builtin_floor_3x3",
      version: 1,
      material_id: 2,
      cells: for(x <- 0..2, y <- 0..2, do: {x, y, 0})
    },
    3 => %{
      id: 3,
      name: "builtin_cube_2x2x2",
      version: 1,
      material_id: 3,
      cells: for(x <- 0..1, y <- 0..1, z <- 0..1, do: {x, y, z})
    }
  }

  @doc "Returns every known blueprint, ordered by `id`."
  @spec all() :: [blueprint()]
  def all do
    @blueprints
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  @doc "Looks up a blueprint by its v1 identifier."
  @spec fetch(non_neg_integer()) ::
          {:ok, blueprint()} | {:error, :unknown_blueprint | :invalid_blueprint_id}
  def fetch(blueprint_id) when is_integer(blueprint_id) and blueprint_id >= 0 do
    case Map.fetch(@blueprints, blueprint_id) do
      {:ok, blueprint} -> {:ok, blueprint}
      :error -> {:error, :unknown_blueprint}
    end
  end

  def fetch(_blueprint_id), do: {:error, :invalid_blueprint_id}

  @doc """
  Validates a `blueprint_id` together with its requested `blueprint_version`.

  v1 only knows blueprint version 1, so any other version is rejected here so
  the rest of the dispatch path can assume a frozen layout.
  """
  @spec fetch(non_neg_integer(), non_neg_integer()) ::
          {:ok, blueprint()}
          | {:error,
             :unknown_blueprint
             | :invalid_blueprint_id
             | :invalid_blueprint_version
             | :blueprint_version_mismatch}
  def fetch(blueprint_id, blueprint_version)
      when is_integer(blueprint_version) and blueprint_version >= 0 do
    with {:ok, blueprint} <- fetch(blueprint_id) do
      if blueprint.version == blueprint_version do
        {:ok, blueprint}
      else
        {:error, :blueprint_version_mismatch}
      end
    end
  end

  def fetch(_blueprint_id, _blueprint_version), do: {:error, :invalid_blueprint_version}
end
