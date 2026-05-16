defmodule SceneServer.Voxel.TagSet do
  @moduledoc """
  Chunk-local pool 内一条 tag 集合（set membership）。

  在 Phase 1.3 阶段：
    * `tag_id` 是 chunk 内局部 u32 ID（与 Phase 5 `TagDefinition` catalog 解耦，
      Phase 5 引入 namespace / merge_rule / name 元数据时再升级）。
    * 不携带 value —— 纯 set membership；要 `(key, value)` 走 `AttributeSet`。
    * 空集禁止入 pool —— `ref = 0` 表 "无 tag set 引用"。
    * pool 内按 `byte_canonical_key/1` 升序排，保证 `chunk_hash` 与输入顺序无关。

  Wire 形式（一旦发出即冻结）：

      <<tag_count::u16, tag_ids::binary>>   # tag_ids = [u32 ...] 升序

  与 `AttributeSet` 的对称：1-indexed ref、chunk-local id、canonical order、
  intern API、chunk_hash 不 bump（空池字节等价）。
  """

  @max_u32 0xFFFF_FFFF

  defstruct tag_ids: []

  @type t :: %__MODULE__{tag_ids: [0..0xFFFF_FFFF]}

  @doc "Builds and validates a TagSet from a keyword / map input."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))
  def new(attrs) when is_map(attrs), do: normalize!(attrs)

  @doc """
  Normalizes a TagSet (or compatible map). Validates each `tag_id`,
  sorts by ascending u32, rejects duplicate ids and empty sets.
  Raises `ArgumentError` on any violation.
  """
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = set) do
    set
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    raw_tag_ids = fetch(attrs, :tag_ids, [])

    unless is_list(raw_tag_ids) do
      raise ArgumentError, "TagSet tag_ids must be a list, got: #{inspect(raw_tag_ids)}"
    end

    Enum.each(raw_tag_ids, &validate_tag_id!/1)

    if raw_tag_ids == [] do
      raise ArgumentError,
            "empty TagSet rejected: empty tag sets must be expressed as " <>
              "tag_set_ref = 0; pool entries must contain at least one tag_id"
    end

    sorted = Enum.sort(raw_tag_ids)

    validate_unique_tag_ids!(sorted)

    %__MODULE__{tag_ids: sorted}
  end

  @doc """
  Returns a binary key suitable for `Enum.sort_by/2` over a TagSet pool.
  Two sets with structurally identical `tag_ids` hash to the same key; sets
  are compared byte-wise per protocol §12.3 canonical encoding rule.
  """
  @spec byte_canonical_key(t()) :: binary()
  def byte_canonical_key(%__MODULE__{} = set) do
    encode_for_wire(set)
  end

  @doc """
  Encodes the set into its wire layout:

      <<tag_count::u16, tag_ids::binary>>     # tag_ids = [u32 ...] 升序
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

  defp do_encode_for_wire(%__MODULE__{tag_ids: tag_ids}) do
    tag_count = length(tag_ids)

    if tag_count > 0xFFFF do
      raise ArgumentError, "TagSet tag_count #{tag_count} exceeds u16 range"
    end

    iodata = [
      <<tag_count::unsigned-big-integer-size(16)>>,
      Enum.map(tag_ids, fn id -> <<id::unsigned-big-integer-size(32)>> end)
    ]

    IO.iodata_to_binary(iodata)
  end

  @doc """
  Decodes one TagSet from the front of `binary`. Returns `{set, rest}`
  or raises on malformed / truncated input.
  """
  @spec decode_for_wire(binary()) :: {t(), binary()}
  def decode_for_wire(<<tag_count::unsigned-big-integer-size(16), rest::binary>>) do
    expected = tag_count * 4

    if byte_size(rest) < expected do
      raise ArgumentError,
            "TagSet payload truncated: expected #{expected} bytes for #{tag_count} tag_ids, " <>
              "got #{byte_size(rest)}"
    end

    <<tag_id_bytes::binary-size(expected), after_tags::binary>> = rest
    tag_ids = decode_tag_ids(tag_id_bytes, [])

    # Trust wire content order; rely on producer canonicalization. Decoded
    # tag_ids are still validated by normalize!/1 to catch out-of-band wire
    # tampering or future spec drift.
    set = normalize!(%{tag_ids: tag_ids})
    {set, after_tags}
  end

  def decode_for_wire(_), do: raise(ArgumentError, "malformed TagSet binary")

  @doc "Converts to a plain map (useful for observe / debug)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{tag_ids: tag_ids}) do
    %{tag_ids: tag_ids}
  end

  # ---- internals --------------------------------------------------------------

  defp decode_tag_ids(<<>>, acc), do: Enum.reverse(acc)

  defp decode_tag_ids(<<id::unsigned-big-integer-size(32), rest::binary>>, acc) do
    decode_tag_ids(rest, [id | acc])
  end

  defp validate_unique_tag_ids!(tag_ids) do
    if length(Enum.uniq(tag_ids)) != length(tag_ids) do
      raise ArgumentError,
            "TagSet contains duplicate tag_id; each tag_id must appear at most once " <>
              "(got: #{inspect(tag_ids)})"
    end
  end

  defp validate_tag_id!(value) when is_integer(value) and value >= 0 and value <= @max_u32,
    do: :ok

  defp validate_tag_id!(other),
    do: raise(ArgumentError, "TagSet tag_id must be u32, got: #{inspect(other)}")

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
