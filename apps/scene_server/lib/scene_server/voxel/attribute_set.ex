defmodule SceneServer.Voxel.AttributeSet do
  @moduledoc """
  Chunk-local pool 内一条 attribute "value bag"：一组 `(key_id, value_type, value)`
  按 `key_id` 升序、键唯一组成的 entries 列表。

  在 Phase 1.2 阶段：
    * `key_id` 是 chunk 内局部 ID（与 Phase 5 `AttributeCatalog` 解耦）。
    * `value_type` ∈ {0x01 i16, 0x02 u16, 0x03 fixed32 Q16.16, 0x04 enum8,
      0x05 bitset32}（见 `SceneServer.Voxel.AttributeEntry`）。
    * 空集禁止入 pool —— `ref = 0` 表 "无 attribute set 引用"。
    * pool 内按 `byte_canonical_key/1` 升序排，保证 `chunk_hash` 与输入顺序无关。

  Wire 形式（一旦发出即冻结）：

      <<entry_count::u16, entries::binary>>
  """

  alias SceneServer.Voxel.AttributeEntry

  defstruct entries: []

  @type t :: %__MODULE__{entries: [AttributeEntry.t()]}

  @doc "Builds and validates an AttributeSet from a keyword / map input."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))
  def new(attrs) when is_map(attrs), do: normalize!(attrs)

  @doc """
  Normalizes an AttributeSet (or compatible map). Validates each entry,
  sorts by `key_id` ascending, rejects duplicate `key_id` and empty sets.
  Raises `ArgumentError` on any violation.
  """
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = set) do
    set
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    raw_entries = fetch(attrs, :entries, [])

    unless is_list(raw_entries) do
      raise ArgumentError, "AttributeSet entries must be a list, got: #{inspect(raw_entries)}"
    end

    entries = Enum.map(raw_entries, &AttributeEntry.normalize!/1)

    if entries == [] do
      raise ArgumentError,
            "empty AttributeSet rejected: empty value bags must be expressed as " <>
              "attribute_set_ref = 0; pool entries must contain at least one AttributeEntry"
    end

    sorted = Enum.sort_by(entries, & &1.key_id)

    validate_unique_key_ids!(sorted)

    %__MODULE__{entries: sorted}
  end

  @doc """
  Returns a binary key suitable for `Enum.sort_by/2` over an AttributeSet pool.
  Two sets with structurally identical entries hash to the same key; sets are
  compared byte-wise per protocol §12.3 canonical encoding rule.
  """
  @spec byte_canonical_key(t()) :: binary()
  def byte_canonical_key(%__MODULE__{} = set) do
    encode_for_wire(set)
  end

  @doc """
  Encodes the set into its wire layout:

      <<entry_count::u16, entries::binary>>
  """
  @spec encode_for_wire(t() | map()) :: binary()
  def encode_for_wire(%__MODULE__{} = set) do
    do_encode_for_wire(set)
  end

  def encode_for_wire(attrs) when is_map(attrs) do
    attrs
    |> normalize!()
    |> do_encode_for_wire()
  end

  defp do_encode_for_wire(%__MODULE__{entries: entries}) do
    entry_count = length(entries)

    if entry_count > 0xFFFF do
      raise ArgumentError, "AttributeSet entry_count #{entry_count} exceeds u16 range"
    end

    iodata = [
      <<entry_count::unsigned-big-integer-size(16)>>,
      Enum.map(entries, &AttributeEntry.encode_to_wire/1)
    ]

    IO.iodata_to_binary(iodata)
  end

  @doc """
  Decodes one AttributeSet from the front of `binary`. Returns `{set, rest}`
  or raises on malformed input / unknown value_type tags.
  """
  @spec decode_for_wire(binary()) :: {t(), binary()}
  def decode_for_wire(<<entry_count::unsigned-big-integer-size(16), rest::binary>>) do
    {entries_rev, after_entries} =
      Enum.reduce(1..entry_count//1, {[], rest}, fn _i, {acc, data} ->
        {entry, next} = AttributeEntry.decode_from_wire(data)
        {[entry | acc], next}
      end)

    entries = Enum.reverse(entries_rev)

    # Trust wire content order; rely on producer canonicalization. Decoded
    # entries are still validated by normalize!/1 to catch out-of-band wire
    # tampering or future spec drift.
    set = normalize!(%{entries: entries})
    {set, after_entries}
  end

  def decode_for_wire(_), do: raise(ArgumentError, "malformed AttributeSet binary")

  @doc "Converts to a plain map (useful for observe / debug)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{entries: entries}) do
    %{
      entries:
        Enum.map(entries, fn entry ->
          %{key_id: entry.key_id, value_type: entry.value_type, value: entry.value}
        end)
    }
  end

  # ---- internals --------------------------------------------------------------

  defp validate_unique_key_ids!(entries) do
    key_ids = Enum.map(entries, & &1.key_id)

    if length(Enum.uniq(key_ids)) != length(key_ids) do
      raise ArgumentError,
            "AttributeSet entries contain duplicate key_id; each key_id must appear at most once " <>
              "(got: #{inspect(key_ids)})"
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
