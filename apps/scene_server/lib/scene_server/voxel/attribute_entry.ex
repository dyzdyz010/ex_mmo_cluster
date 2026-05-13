defmodule SceneServer.Voxel.AttributeEntry do
  @moduledoc """
  单条 attribute 键值对，参与 chunk-local `AttributeSet` pool。

  Phase 1.2 wire 形式（一旦发出即冻结）：

      key_id      u32
      value_type  u8   (0x01 i16 / 0x02 u16 / 0x03 fixed32 Q16.16 /
                        0x04 enum8 / 0x05 bitset32)
      value       <var>  (size 由 value_type 决定，见 `value_type_payload_size/1`)

  `key_id` 在 Phase 1.2 阶段是 "chunk 内局部 ID"，与 Phase 5 `AttributeCatalog`
  解耦；wire 层不解释其语义。`value` 字段的范围由 `value_type` tag 决定。
  """

  @value_type_i16 0x01
  @value_type_u16 0x02
  @value_type_fixed32 0x03
  @value_type_enum8 0x04
  @value_type_bitset32 0x05

  @max_u32 0xFFFF_FFFF

  defstruct key_id: 0, value_type: @value_type_i16, value: 0

  @type value_type :: 0x01 | 0x02 | 0x03 | 0x04 | 0x05
  @type t :: %__MODULE__{
          key_id: 0..0xFFFF_FFFF,
          value_type: value_type(),
          value: integer()
        }

  @doc "Returns the value_type tag for i16 (0x01)."
  def value_type_i16, do: @value_type_i16

  @doc "Returns the value_type tag for u16 (0x02)."
  def value_type_u16, do: @value_type_u16

  @doc "Returns the value_type tag for fixed32 Q16.16 (0x03)."
  def value_type_fixed32, do: @value_type_fixed32

  @doc "Returns the value_type tag for enum8 (0x04)."
  def value_type_enum8, do: @value_type_enum8

  @doc "Returns the value_type tag for bitset32 (0x05)."
  def value_type_bitset32, do: @value_type_bitset32

  @doc """
  Validates and normalizes a single attribute entry. Raises `ArgumentError`
  on out-of-range / unknown-tag inputs.
  """
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = entry) do
    entry
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    key_id = fetch(attrs, :key_id, 0)
    value_type = fetch(attrs, :value_type, @value_type_i16)
    value = fetch(attrs, :value, 0)

    validate_key_id!(key_id)
    validate_value_type!(value_type)
    validate_value!(value_type, value)

    %__MODULE__{key_id: key_id, value_type: value_type, value: value}
  end

  @doc """
  Encodes one entry into its wire layout:

      <<key_id::u32, value_type::u8, value::var>>
  """
  @spec encode_to_wire(t() | map()) :: binary()
  def encode_to_wire(entry) do
    entry = normalize!(entry)

    [
      <<entry.key_id::unsigned-big-integer-size(32)>>,
      <<entry.value_type::unsigned-integer-size(8)>>,
      encode_value(entry.value_type, entry.value)
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Decodes one entry from the front of `binary`. Returns `{entry, rest}` or
  raises `ArgumentError` if the value_type tag is unknown.
  """
  @spec decode_from_wire(binary()) :: {t(), binary()}
  def decode_from_wire(<<key_id::unsigned-big-integer-size(32),
                         value_type::unsigned-integer-size(8),
                         rest::binary>>) do
    validate_value_type!(value_type)

    {value, after_value} = decode_value(value_type, rest)

    entry = %__MODULE__{key_id: key_id, value_type: value_type, value: value}
    {entry, after_value}
  end

  def decode_from_wire(_), do: raise(ArgumentError, "malformed AttributeEntry binary")

  @doc """
  Returns the wire payload size (in bytes) of an entry's `value` field for a
  given `value_type`. Useful for static byte accounting.
  """
  @spec value_type_payload_size(value_type()) :: 1 | 2 | 4
  def value_type_payload_size(@value_type_i16), do: 2
  def value_type_payload_size(@value_type_u16), do: 2
  def value_type_payload_size(@value_type_fixed32), do: 4
  def value_type_payload_size(@value_type_enum8), do: 1
  def value_type_payload_size(@value_type_bitset32), do: 4

  # ---- internals --------------------------------------------------------------

  defp encode_value(@value_type_i16, value),
    do: <<value::signed-big-integer-size(16)>>

  defp encode_value(@value_type_u16, value),
    do: <<value::unsigned-big-integer-size(16)>>

  defp encode_value(@value_type_fixed32, value),
    do: <<value::signed-big-integer-size(32)>>

  defp encode_value(@value_type_enum8, value),
    do: <<value::unsigned-integer-size(8)>>

  defp encode_value(@value_type_bitset32, value),
    do: <<value::unsigned-big-integer-size(32)>>

  defp decode_value(@value_type_i16, <<v::signed-big-integer-size(16), rest::binary>>),
    do: {v, rest}

  defp decode_value(@value_type_u16, <<v::unsigned-big-integer-size(16), rest::binary>>),
    do: {v, rest}

  defp decode_value(@value_type_fixed32, <<v::signed-big-integer-size(32), rest::binary>>),
    do: {v, rest}

  defp decode_value(@value_type_enum8, <<v::unsigned-integer-size(8), rest::binary>>),
    do: {v, rest}

  defp decode_value(@value_type_bitset32, <<v::unsigned-big-integer-size(32), rest::binary>>),
    do: {v, rest}

  defp decode_value(_value_type, _data),
    do: raise(ArgumentError, "AttributeEntry value payload truncated")

  defp validate_key_id!(value) when is_integer(value) and value >= 0 and value <= @max_u32, do: :ok

  defp validate_key_id!(other),
    do: raise(ArgumentError, "AttributeEntry key_id must be u32, got: #{inspect(other)}")

  defp validate_value_type!(vt)
       when vt in [
              @value_type_i16,
              @value_type_u16,
              @value_type_fixed32,
              @value_type_enum8,
              @value_type_bitset32
            ],
       do: :ok

  defp validate_value_type!(other),
    do:
      raise(
        ArgumentError,
        "unknown AttributeEntry value_type tag #{inspect(other)} (expected 0x01..0x05)"
      )

  defp validate_value!(@value_type_i16, v)
       when is_integer(v) and v >= -0x8000 and v <= 0x7FFF,
       do: :ok

  defp validate_value!(@value_type_u16, v)
       when is_integer(v) and v >= 0 and v <= 0xFFFF,
       do: :ok

  defp validate_value!(@value_type_fixed32, v)
       when is_integer(v) and v >= -0x8000_0000 and v <= 0x7FFF_FFFF,
       do: :ok

  defp validate_value!(@value_type_enum8, v)
       when is_integer(v) and v >= 0 and v <= 0xFF,
       do: :ok

  defp validate_value!(@value_type_bitset32, v)
       when is_integer(v) and v >= 0 and v <= 0xFFFF_FFFF,
       do: :ok

  defp validate_value!(value_type, v),
    do:
      raise(
        ArgumentError,
        "AttributeEntry value #{inspect(v)} out of range for value_type 0x#{Integer.to_string(value_type, 16)}"
      )

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
