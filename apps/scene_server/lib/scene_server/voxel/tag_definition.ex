defmodule SceneServer.Voxel.TagDefinition do
  @moduledoc """
  Phase 5.B TagDefinition v1 schema：全局 tag catalog 单条定义。

  Phase 1.3 chunk-local `SceneServer.Voxel.TagSet.tag_ids` 元素在 Phase 5.B 之后
  语义升级为本模块的 `id`（catalog 全局 id）；wire 字段不变（仍 u32）。

  与 Phase 5.A `AttributeDefinition` 对称但**更简单**：tag 只携带 `id + name`，
  无 `value_type / default / min / max / merge_rule / dynamic`（Phase 1.3 T-2 决策
  "不携带 value"）。

  Wire 形式（在 `TagCatalogSnapshot` 内一次出现一条，一旦发出即冻结）：

      id        u32
      name_len  u16
      name      bytes(name_len)        # UTF-8, 非空

  校验规则：
    * `name` 必须为非空合法 UTF-8。
    * `id` 必须在 u32 范围（0..0xFFFF_FFFF）。
  """

  @max_u16 0xFFFF
  @max_u32 0xFFFF_FFFF

  defstruct id: 0, name: ""

  @type t :: %__MODULE__{
          id: 0..0xFFFF_FFFF,
          name: String.t()
        }

  # ---- constructors / normalize ----------------------------------------------

  @doc "Builds and validates a TagDefinition from keyword / map input."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))
  def new(attrs) when is_map(attrs), do: normalize!(attrs)

  @doc """
  Normalizes a TagDefinition (or compatible map). Validates all fields
  and raises `ArgumentError` on any violation.
  """
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = defn) do
    defn
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    id = fetch(attrs, :id, 0)
    name = fetch(attrs, :name, "")

    validate_id!(id)
    validate_name!(name)

    %__MODULE__{id: id, name: name}
  end

  # ---- wire encode ------------------------------------------------------------

  @doc """
  Encodes one definition to its wire layout. Validates struct fields at the wire
  boundary. Caller is responsible for framing definitions into an enclosing
  `TagCatalogSnapshot` (this function emits only the definition record).
  """
  @spec encode_for_wire(t() | map()) :: binary()
  def encode_for_wire(%__MODULE__{} = defn) do
    do_encode_for_wire(defn)
  end

  def encode_for_wire(attrs) when is_map(attrs) do
    attrs
    |> normalize!()
    |> do_encode_for_wire()
  end

  defp do_encode_for_wire(%__MODULE__{} = defn) do
    name_bin = defn.name

    if not is_binary(name_bin) do
      raise ArgumentError,
            "TagDefinition name must be a binary on encode, got: #{inspect(name_bin)}"
    end

    name_len = byte_size(name_bin)

    if name_len > @max_u16 do
      raise ArgumentError,
            "TagDefinition name_len #{name_len} exceeds u16 range (#{@max_u16})"
    end

    validate_id!(defn.id)
    validate_name!(name_bin)

    [
      <<defn.id::unsigned-big-integer-size(32)>>,
      <<name_len::unsigned-big-integer-size(16)>>,
      name_bin
    ]
    |> IO.iodata_to_binary()
  end

  # ---- wire decode ------------------------------------------------------------

  @doc """
  Decodes one definition from the front of `binary`. Returns `{defn, rest}` or
  raises `ArgumentError` on malformed input.
  """
  @spec decode_from_wire(binary()) :: {t(), binary()}
  def decode_from_wire(
        <<id::unsigned-big-integer-size(32), name_len::unsigned-big-integer-size(16),
          rest1::binary>>
      ) do
    case rest1 do
      <<name::binary-size(^name_len), rest2::binary>> ->
        # Re-run normalize to enforce non-empty / UTF-8 at the wire boundary;
        # catches out-of-band wire tampering or future drift.
        defn = normalize!(%{id: id, name: name})
        {defn, rest2}

      _ ->
        raise ArgumentError, "TagDefinition name payload truncated"
    end
  end

  def decode_from_wire(_), do: raise(ArgumentError, "malformed TagDefinition binary")

  # ---- internals: validation --------------------------------------------------

  defp validate_id!(value) when is_integer(value) and value >= 0 and value <= @max_u32, do: :ok

  defp validate_id!(other),
    do: raise(ArgumentError, "TagDefinition id must be u32, got: #{inspect(other)}")

  defp validate_name!(value) when is_binary(value) do
    cond do
      byte_size(value) == 0 ->
        raise ArgumentError, "TagDefinition name must be non-empty"

      not String.valid?(value) ->
        raise ArgumentError,
              "TagDefinition name must be valid UTF-8, got: #{inspect(value)}"

      byte_size(value) > @max_u16 ->
        raise ArgumentError,
              "TagDefinition name byte size #{byte_size(value)} exceeds u16 range"

      true ->
        :ok
    end
  end

  defp validate_name!(other),
    do: raise(ArgumentError, "TagDefinition name must be a string, got: #{inspect(other)}")

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
