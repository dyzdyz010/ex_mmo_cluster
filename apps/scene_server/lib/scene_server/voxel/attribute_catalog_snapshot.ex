defmodule SceneServer.Voxel.AttributeCatalogSnapshot do
  @moduledoc """
  Phase 5.A AttributeCatalogSnapshot 全量 catalog wire 类型，opcode `0x6E`。

  作为客户端冷启动 / 重连 / catalog 大幅变更时的"基线"通道；增量更新走
  Phase 1.4 `SceneServer.Voxel.CatalogPatch` envelope（opcode `0x71`）。

  Phase 1.2 chunk-local `AttributeEntry.key_id` 在本 commit 后语义升级为本
  catalog 内 `AttributeDefinition.id`（catalog 全局 id）；wire 字段不变（仍 u32）。

  设计草案：`docs/plans/2026-05-13-phase5a-attribute-catalog-snapshot.md`
  （A-1..A-6 全部推荐方案，用户 2026-05-13 approve）。

  Wire layout (opcode `0x6E`, payload only, 一旦发出即冻结)：

      catalog_version: u64
      definition_count: u32
      definitions[definition_count] {
        id:           u32
        name_len:     u16
        name:         bytes(name_len)        # UTF-8, 非空
        unit_len:     u16
        unit:         bytes(unit_len)        # UTF-8, 允许为空
        value_type:   u8
        default_value bytes(N)               # N = value_type 字节长度 (2/2/4/1/4)
        min_value     bytes(N)
        max_value     bytes(N)
        merge_rule    u8
        dynamic       u8
      }

  本模块仅产出 / 解析 payload；不含 opcode byte。Gate codec 集成 / 客户端
  decoder 与 catalog 持久化 (DataService schema) 不在 Phase 5.A 范围，
  推到 Phase 5.C / 5.D。

  `definitions` 在 `normalize!/1` 内按 `id` 升序去重；`encode_for_wire`
  顺手再 sort 一遍，保 wire 字节序唯一。重复 id 直接 raise。
  """

  alias SceneServer.Voxel.AttributeDefinition

  @max_u32 0xFFFF_FFFF
  @max_u64 0xFFFF_FFFF_FFFF_FFFF

  defstruct catalog_version: 0, definitions: []

  @type t :: %__MODULE__{
          catalog_version: 0..0xFFFF_FFFF_FFFF_FFFF,
          definitions: [AttributeDefinition.t()]
        }

  # ---- constructors / normalize ----------------------------------------------

  @doc "Builds and validates an AttributeCatalogSnapshot from keyword / map input."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))
  def new(attrs) when is_map(attrs), do: normalize!(attrs)

  @doc """
  Normalizes a snapshot (or compatible map). Validates `catalog_version` is in
  u64 range, each definition via `AttributeDefinition.normalize!/1`, then
  sorts definitions by `id` ascending and rejects duplicate ids. Raises
  `ArgumentError` on any violation.
  """
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = snap) do
    snap
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    catalog_version = fetch(attrs, :catalog_version, 0)
    raw_definitions = fetch(attrs, :definitions, [])

    validate_catalog_version!(catalog_version)

    unless is_list(raw_definitions) do
      raise ArgumentError,
            "AttributeCatalogSnapshot definitions must be a list, got: #{inspect(raw_definitions)}"
    end

    if length(raw_definitions) > @max_u32 do
      raise ArgumentError,
            "AttributeCatalogSnapshot definition_count #{length(raw_definitions)} " <>
              "exceeds u32 range (#{@max_u32})"
    end

    definitions =
      raw_definitions
      |> Enum.map(&AttributeDefinition.normalize!/1)
      |> Enum.sort_by(& &1.id)

    validate_unique_ids!(definitions)

    %__MODULE__{catalog_version: catalog_version, definitions: definitions}
  end

  # ---- wire encode ------------------------------------------------------------

  @doc """
  Encodes the snapshot payload (no opcode byte prefix). Validates struct
  fields at the wire boundary.
  """
  @spec encode_for_wire(t() | map()) :: binary()
  def encode_for_wire(%__MODULE__{} = snap) do
    do_encode_for_wire(snap)
  end

  def encode_for_wire(attrs) when is_map(attrs) do
    attrs
    |> normalize!()
    |> do_encode_for_wire()
  end

  defp do_encode_for_wire(%__MODULE__{
         catalog_version: catalog_version,
         definitions: definitions
       }) do
    # Re-run wire-boundary guards: catalog_version u64 + definition_count u32.
    validate_catalog_version!(catalog_version)

    # Re-sort + dedupe defense (callers may have hand-built a struct without
    # going through normalize!/1).
    sorted =
      definitions
      |> Enum.map(&AttributeDefinition.normalize!/1)
      |> Enum.sort_by(& &1.id)

    validate_unique_ids!(sorted)

    definition_count = length(sorted)

    if definition_count > @max_u32 do
      raise ArgumentError,
            "AttributeCatalogSnapshot definition_count #{definition_count} " <>
              "exceeds u32 range (#{@max_u32})"
    end

    iodata = [
      <<catalog_version::unsigned-big-integer-size(64)>>,
      <<definition_count::unsigned-big-integer-size(32)>>,
      Enum.map(sorted, &AttributeDefinition.encode_for_wire/1)
    ]

    IO.iodata_to_binary(iodata)
  end

  # ---- wire decode ------------------------------------------------------------

  @doc """
  Decodes the snapshot payload (no opcode byte prefix). Returns the typed
  struct or raises `ArgumentError` on malformed / truncated input.
  """
  @spec decode_for_wire(binary()) :: t()
  def decode_for_wire(
        <<catalog_version::unsigned-big-integer-size(64),
          definition_count::unsigned-big-integer-size(32), rest::binary>>
      ) do
    validate_catalog_version!(catalog_version)

    {definitions_rev, after_defs} =
      Enum.reduce(1..definition_count//1, {[], rest}, fn _i, {acc, data} ->
        {defn, next} = AttributeDefinition.decode_from_wire(data)
        {[defn | acc], next}
      end)

    if after_defs != <<>> do
      raise ArgumentError,
            "AttributeCatalogSnapshot has #{byte_size(after_defs)} trailing bytes after " <>
              "decoding #{definition_count} definitions"
    end

    definitions = Enum.reverse(definitions_rev)

    # Re-run normalize to enforce id-asc + uniqueness at the wire boundary;
    # this catches out-of-band wire tampering or future producer drift.
    normalize!(%{catalog_version: catalog_version, definitions: definitions})
  end

  def decode_for_wire(_),
    do: raise(ArgumentError, "malformed AttributeCatalogSnapshot binary")

  # ---- internals --------------------------------------------------------------

  defp validate_catalog_version!(value)
       when is_integer(value) and value >= 0 and value <= @max_u64,
       do: :ok

  defp validate_catalog_version!(other) do
    raise ArgumentError,
          "AttributeCatalogSnapshot catalog_version must be u64 (0..#{@max_u64}); " <>
            "got: #{inspect(other)}"
  end

  defp validate_unique_ids!(definitions) do
    ids = Enum.map(definitions, & &1.id)

    if length(Enum.uniq(ids)) != length(ids) do
      raise ArgumentError,
            "AttributeCatalogSnapshot definitions contain duplicate id; each id must " <>
              "appear at most once (got: #{inspect(ids)})"
    end
  end

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
