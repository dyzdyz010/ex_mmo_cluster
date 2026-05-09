defmodule SceneServer.Voxel.BlueprintCatalog do
  @moduledoc """
  Server-side catalog of v2 hardcoded voxel prefab blueprints.

  Phase A1 升级 v1 → v2:每个 blueprint 现在携带一个 micro occupancy mask
  (single-macro 范围,8³=512 micro slots),不再是 macro cell offset list。
  Server-side 跟客户端 `clients/web_client/src/voxel/prefab/definitions.ts`
  的几何函数(球/圆柱/阶梯距离判定)用同一公式 compile-time 计算 mask,
  保证两端形状像素级一致。

  v2 blueprint set:

    1. `builtin_sphere`     (material Ice = 4):球体,居中半径 ≈ 3.9 micro
    2. `builtin_cylinder`   (material Stone = 2):z 轴圆柱,半径同上
    3. `builtin_stairs`     (material Wood = 3):y ≤ x 阶梯

  Out of scope for v2:

    - rotation(callers must always pass `rotation: 0`)
    - 跨 macro prefab(占用范围 > 1×1×1 macro)
    - parcel build epoch / per-prefab part 多元素
    - 不留 v1 macro-list 兼容(memory:全新未上线系统不留 wrapper)
  """

  import Bitwise

  @micro_resolution 8
  @blueprint_version 2

  @typedoc "Linear micro slot index, `0..511` = `x + y*8 + z*64`."
  @type micro_slot :: 0..511

  @typedoc """
  v2 blueprint definition.

  `occupied_slots` is the list of micro slot linear indices the blueprint
  fills (deterministic ascending order). `material_id` is the fixed normal-block
  material applied to every slot. `version` matches the blueprint version
  negotiated on the wire.
  """
  @type blueprint :: %{
          id: pos_integer(),
          name: String.t(),
          version: pos_integer(),
          material_id: 0..0xFFFF,
          occupied_slots: [micro_slot()]
        }

  # Compile-time geometry — same formula as
  # `clients/web_client/src/voxel/prefab/definitions.ts`:
  # sphere/cylinder use distance from center; stairs use y ≤ x.
  # Inlined as module attributes so private helpers don't have to exist
  # before the attribute body is evaluated.

  @sphere_slots (for x <- 0..(@micro_resolution - 1),
                     y <- 0..(@micro_resolution - 1),
                     z <- 0..(@micro_resolution - 1),
                     dx = x + 0.5 - @micro_resolution / 2.0,
                     dy = y + 0.5 - @micro_resolution / 2.0,
                     dz = z + 0.5 - @micro_resolution / 2.0,
                     dx * dx + dy * dy + dz * dz <=
                       (@micro_resolution / 2.0 - 0.1) *
                         (@micro_resolution / 2.0 - 0.1) do
                   x + y * @micro_resolution +
                     z * @micro_resolution * @micro_resolution
                 end)

  @cylinder_slots (for x <- 0..(@micro_resolution - 1),
                       y <- 0..(@micro_resolution - 1),
                       z <- 0..(@micro_resolution - 1),
                       dx = x + 0.5 - @micro_resolution / 2.0,
                       dz = z + 0.5 - @micro_resolution / 2.0,
                       dx * dx + dz * dz <=
                         (@micro_resolution / 2.0 - 0.1) *
                           (@micro_resolution / 2.0 - 0.1) do
                     x + y * @micro_resolution +
                       z * @micro_resolution * @micro_resolution
                   end)

  @stairs_slots (for x <- 0..(@micro_resolution - 1),
                     y <- 0..(@micro_resolution - 1),
                     z <- 0..(@micro_resolution - 1),
                     y <= x do
                   x + y * @micro_resolution +
                     z * @micro_resolution * @micro_resolution
                 end)

  @blueprints %{
    1 => %{
      id: 1,
      name: "builtin_sphere",
      version: @blueprint_version,
      material_id: 4,
      occupied_slots: @sphere_slots
    },
    2 => %{
      id: 2,
      name: "builtin_cylinder",
      version: @blueprint_version,
      material_id: 2,
      occupied_slots: @cylinder_slots
    },
    3 => %{
      id: 3,
      name: "builtin_stairs",
      version: @blueprint_version,
      material_id: 3,
      occupied_slots: @stairs_slots
    }
  }

  @doc "Returns every known blueprint, ordered by `id`."
  @spec all() :: [blueprint()]
  def all do
    @blueprints
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  @doc "Returns the canonical wire-level blueprint version."
  @spec blueprint_version() :: pos_integer()
  def blueprint_version, do: @blueprint_version

  @doc "Returns total occupied slot count for the blueprint id (for tests / observability)."
  @spec slot_count(non_neg_integer()) :: non_neg_integer() | nil
  def slot_count(blueprint_id) do
    case Map.fetch(@blueprints, blueprint_id) do
      {:ok, blueprint} -> length(blueprint.occupied_slots)
      :error -> nil
    end
  end

  @doc "Looks up a blueprint by its v2 identifier."
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

  v2 only knows blueprint version 2; older payloads (v1 macro-list) are rejected
  with `:blueprint_version_mismatch` so the rest of the dispatch path can assume
  the v2 layout (occupied_slots is always present and 0..511).
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

  @doc """
  Returns true if the linear `slot_index` is part of the blueprint's occupancy
  mask. Used by tests / debug tooling — the dispatch path expands
  `occupied_slots` directly.
  """
  @spec slot_occupied?(blueprint(), micro_slot()) :: boolean()
  def slot_occupied?(blueprint, slot_index) when is_integer(slot_index) do
    blueprint.occupied_slots
    |> Enum.any?(&(&1 == slot_index))
  end

  @doc """
  Convenience: returns the unsigned integer 64-bit "occupancy word" array for a
  blueprint (8 words for 512 slots). Mirrors the client-side `occupancyWord`
  representation in `prefab/definitions.ts` so wire-level / RPC layers can
  produce the same bigint mask without re-running the geometry.
  """
  @spec occupancy_words(blueprint()) :: [non_neg_integer()]
  def occupancy_words(blueprint) do
    Enum.reduce(blueprint.occupied_slots, List.duplicate(0, 8), fn slot, words ->
      word_index = div(slot, 64)
      bit_index = rem(slot, 64)
      List.update_at(words, word_index, &bor(&1, 1 <<< bit_index))
    end)
  end
end
