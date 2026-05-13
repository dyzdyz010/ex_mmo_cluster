defmodule SceneServer.Voxel.AttributeDefinition do
  @moduledoc """
  Phase 5.A AttributeDefinition v1 schema：全局 attribute catalog 单条定义。

  Phase 1.2 `SceneServer.Voxel.AttributeEntry.key_id` 在 Phase 5.A 之后
  语义升级为本模块的 `id`（catalog 全局 id）；wire 字段不变（仍 u32）。

  设计草案：`docs/plans/2026-05-13-phase5a-attribute-catalog-snapshot.md`
  （A-1..A-6 全部推荐方案，用户 2026-05-13 approve）。

  Wire 形式（在 `AttributeCatalogSnapshot` 内一次出现一条，一旦发出即冻结）：

      id            u32
      name_len      u16
      name          bytes(name_len)        # UTF-8, 非空
      unit_len      u16
      unit          bytes(unit_len)        # UTF-8, 允许为空（unitless）
      value_type    u8                     # 0x01 i16 / 0x02 u16 / 0x03 fixed32 / 0x04 enum8 / 0x05 bitset32
      default_value bytes(N)               # N = value_type 字节长度 (2/2/4/1/4)
      min_value     bytes(N)
      max_value     bytes(N)
      merge_rule    u8                     # 0x01 override / 0x02 add_delta / 0x03 max / 0x04 min / 0x05 material_default
      dynamic       u8                     # 0 / 1

  校验规则：
    * `name` 必须为非空合法 UTF-8。
    * `unit` 允许为空字符串（unitless attribute，例如 boolean / enum）；非空时必须合法 UTF-8。
    * `value_type` ∈ {0x01..0x05}（与 Phase 1.2 `AttributeEntry` 完全一致）。
    * `default_value` / `min_value` / `max_value` 范围与 `value_type` 一致。
    * `min_value <= default_value <= max_value`。
    * `merge_rule` ∈ {0x01..0x05}。
    * `dynamic` ∈ {0, 1}。
  """

  alias SceneServer.Voxel.AttributeEntry

  @value_type_i16 0x01
  @value_type_u16 0x02
  @value_type_fixed32 0x03
  @value_type_enum8 0x04
  @value_type_bitset32 0x05

  @merge_override 0x01
  @merge_add_delta 0x02
  @merge_max 0x03
  @merge_min 0x04
  @merge_material_default 0x05

  @max_u16 0xFFFF
  @max_u32 0xFFFF_FFFF

  defstruct id: 0,
            name: "",
            unit: "",
            value_type: @value_type_i16,
            default_value: 0,
            min_value: 0,
            max_value: 0,
            merge_rule: @merge_override,
            dynamic: false

  @type value_type :: 0x01 | 0x02 | 0x03 | 0x04 | 0x05
  @type merge_rule :: 0x01 | 0x02 | 0x03 | 0x04 | 0x05
  @type t :: %__MODULE__{
          id: 0..0xFFFF_FFFF,
          name: String.t(),
          unit: String.t(),
          value_type: value_type(),
          default_value: integer(),
          min_value: integer(),
          max_value: integer(),
          merge_rule: merge_rule(),
          dynamic: boolean()
        }

  # ---- public value_type helpers (与 AttributeEntry 对齐) ---------------------

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

  # ---- public merge_rule helpers ---------------------------------------------

  @doc "merge_rule tag: override (0x01)."
  def merge_override, do: @merge_override

  @doc "merge_rule tag: add_delta (0x02)."
  def merge_add_delta, do: @merge_add_delta

  @doc "merge_rule tag: max (0x03)."
  def merge_max, do: @merge_max

  @doc "merge_rule tag: min (0x04)."
  def merge_min, do: @merge_min

  @doc "merge_rule tag: material_default (0x05)."
  def merge_material_default, do: @merge_material_default

  # ---- constructors / normalize ----------------------------------------------

  @doc "Builds and validates an AttributeDefinition from keyword / map input."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))
  def new(attrs) when is_map(attrs), do: normalize!(attrs)

  @doc """
  Normalizes an AttributeDefinition (or compatible map). Validates all fields
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
    unit = fetch(attrs, :unit, "")
    value_type = fetch(attrs, :value_type, @value_type_i16)
    default_value = fetch(attrs, :default_value, 0)
    min_value = fetch(attrs, :min_value, 0)
    max_value = fetch(attrs, :max_value, 0)
    merge_rule = fetch(attrs, :merge_rule, @merge_override)
    dynamic = fetch(attrs, :dynamic, false)

    validate_id!(id)
    validate_name!(name)
    validate_unit!(unit)
    validate_value_type!(value_type)
    validate_typed_value!(value_type, default_value, :default_value)
    validate_typed_value!(value_type, min_value, :min_value)
    validate_typed_value!(value_type, max_value, :max_value)
    validate_min_default_max!(min_value, default_value, max_value)
    validate_merge_rule!(merge_rule)
    dynamic_bool = validate_dynamic!(dynamic)

    %__MODULE__{
      id: id,
      name: name,
      unit: unit,
      value_type: value_type,
      default_value: default_value,
      min_value: min_value,
      max_value: max_value,
      merge_rule: merge_rule,
      dynamic: dynamic_bool
    }
  end

  # ---- wire encode ------------------------------------------------------------

  @doc """
  Encodes one definition to its wire layout. Validates struct fields at the wire
  boundary. Caller is responsible for framing definitions into an enclosing
  `AttributeCatalogSnapshot` (this function emits only the definition record).
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
    unit_bin = defn.unit

    if not is_binary(name_bin) do
      raise ArgumentError,
            "AttributeDefinition name must be a binary on encode, got: #{inspect(name_bin)}"
    end

    if not is_binary(unit_bin) do
      raise ArgumentError,
            "AttributeDefinition unit must be a binary on encode, got: #{inspect(unit_bin)}"
    end

    name_len = byte_size(name_bin)
    unit_len = byte_size(unit_bin)

    if name_len > @max_u16 do
      raise ArgumentError,
            "AttributeDefinition name_len #{name_len} exceeds u16 range (#{@max_u16})"
    end

    if unit_len > @max_u16 do
      raise ArgumentError,
            "AttributeDefinition unit_len #{unit_len} exceeds u16 range (#{@max_u16})"
    end

    validate_id!(defn.id)
    validate_value_type!(defn.value_type)
    validate_merge_rule!(defn.merge_rule)

    [
      <<defn.id::unsigned-big-integer-size(32)>>,
      <<name_len::unsigned-big-integer-size(16)>>,
      name_bin,
      <<unit_len::unsigned-big-integer-size(16)>>,
      unit_bin,
      <<defn.value_type::unsigned-integer-size(8)>>,
      encode_typed_value(defn.value_type, defn.default_value),
      encode_typed_value(defn.value_type, defn.min_value),
      encode_typed_value(defn.value_type, defn.max_value),
      <<defn.merge_rule::unsigned-integer-size(8)>>,
      <<encode_dynamic(defn.dynamic)::unsigned-integer-size(8)>>
    ]
    |> IO.iodata_to_binary()
  end

  # ---- wire decode ------------------------------------------------------------

  @doc """
  Decodes one definition from the front of `binary`. Returns `{defn, rest}` or
  raises `ArgumentError` on malformed input / unknown enum values.
  """
  @spec decode_from_wire(binary()) :: {t(), binary()}
  def decode_from_wire(
        <<id::unsigned-big-integer-size(32), name_len::unsigned-big-integer-size(16),
          rest1::binary>>
      ) do
    case rest1 do
      <<name::binary-size(name_len), unit_len::unsigned-big-integer-size(16), rest2::binary>> ->
        case rest2 do
          <<unit::binary-size(unit_len), value_type::unsigned-integer-size(8), rest3::binary>> ->
            validate_value_type!(value_type)
            n = value_payload_size(value_type)

            case rest3 do
              <<default_raw::binary-size(n), min_raw::binary-size(n), max_raw::binary-size(n),
                merge_rule::unsigned-integer-size(8), dynamic_u8::unsigned-integer-size(8),
                rest4::binary>> ->
                default_value = decode_typed_value(value_type, default_raw)
                min_value = decode_typed_value(value_type, min_raw)
                max_value = decode_typed_value(value_type, max_raw)

                # Re-run normalize to enforce ordering / merge_rule / dynamic at the
                # wire boundary; catches out-of-band wire tampering or future drift.
                defn =
                  normalize!(%{
                    id: id,
                    name: name,
                    unit: unit,
                    value_type: value_type,
                    default_value: default_value,
                    min_value: min_value,
                    max_value: max_value,
                    merge_rule: merge_rule,
                    dynamic: dynamic_u8
                  })

                {defn, rest4}

              _ ->
                raise ArgumentError, "AttributeDefinition value payload truncated"
            end

          _ ->
            raise ArgumentError, "AttributeDefinition unit payload truncated"
        end

      _ ->
        raise ArgumentError, "AttributeDefinition name payload truncated"
    end
  end

  def decode_from_wire(_), do: raise(ArgumentError, "malformed AttributeDefinition binary")

  @doc """
  Returns the wire payload byte size for a definition's `default_value` /
  `min_value` / `max_value` field given a `value_type` tag. Delegates to
  Phase 1.2 `AttributeEntry.value_type_payload_size/1` so the two stay in
  lockstep.
  """
  @spec value_payload_size(value_type()) :: 1 | 2 | 4
  def value_payload_size(value_type), do: AttributeEntry.value_type_payload_size(value_type)

  # ---- internals: typed value encode / decode ---------------------------------

  defp encode_typed_value(@value_type_i16, v),
    do: <<v::signed-big-integer-size(16)>>

  defp encode_typed_value(@value_type_u16, v),
    do: <<v::unsigned-big-integer-size(16)>>

  defp encode_typed_value(@value_type_fixed32, v),
    do: <<v::signed-big-integer-size(32)>>

  defp encode_typed_value(@value_type_enum8, v),
    do: <<v::unsigned-integer-size(8)>>

  defp encode_typed_value(@value_type_bitset32, v),
    do: <<v::unsigned-big-integer-size(32)>>

  defp decode_typed_value(@value_type_i16, <<v::signed-big-integer-size(16)>>), do: v
  defp decode_typed_value(@value_type_u16, <<v::unsigned-big-integer-size(16)>>), do: v
  defp decode_typed_value(@value_type_fixed32, <<v::signed-big-integer-size(32)>>), do: v
  defp decode_typed_value(@value_type_enum8, <<v::unsigned-integer-size(8)>>), do: v
  defp decode_typed_value(@value_type_bitset32, <<v::unsigned-big-integer-size(32)>>), do: v

  defp encode_dynamic(true), do: 1
  defp encode_dynamic(false), do: 0
  defp encode_dynamic(1), do: 1
  defp encode_dynamic(0), do: 0

  defp encode_dynamic(other) do
    raise ArgumentError,
          "AttributeDefinition dynamic must be true/false or 0/1, got: #{inspect(other)}"
  end

  # ---- internals: validation --------------------------------------------------

  defp validate_id!(value) when is_integer(value) and value >= 0 and value <= @max_u32, do: :ok

  defp validate_id!(other),
    do: raise(ArgumentError, "AttributeDefinition id must be u32, got: #{inspect(other)}")

  defp validate_name!(value) when is_binary(value) do
    cond do
      byte_size(value) == 0 ->
        raise ArgumentError, "AttributeDefinition name must be non-empty"

      not String.valid?(value) ->
        raise ArgumentError,
              "AttributeDefinition name must be valid UTF-8, got: #{inspect(value)}"

      byte_size(value) > @max_u16 ->
        raise ArgumentError,
              "AttributeDefinition name byte size #{byte_size(value)} exceeds u16 range"

      true ->
        :ok
    end
  end

  defp validate_name!(other),
    do: raise(ArgumentError, "AttributeDefinition name must be a string, got: #{inspect(other)}")

  defp validate_unit!(value) when is_binary(value) do
    cond do
      # unit 允许为空（unitless attribute，例如 boolean / enum），与设计草案 §2.2 一致。
      byte_size(value) == 0 ->
        :ok

      not String.valid?(value) ->
        raise ArgumentError,
              "AttributeDefinition unit must be valid UTF-8, got: #{inspect(value)}"

      byte_size(value) > @max_u16 ->
        raise ArgumentError,
              "AttributeDefinition unit byte size #{byte_size(value)} exceeds u16 range"

      true ->
        :ok
    end
  end

  defp validate_unit!(other),
    do: raise(ArgumentError, "AttributeDefinition unit must be a string, got: #{inspect(other)}")

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
        "unknown AttributeDefinition value_type tag #{inspect(other)} (expected 0x01..0x05)"
      )

  defp validate_typed_value!(@value_type_i16, v, _field)
       when is_integer(v) and v >= -0x8000 and v <= 0x7FFF,
       do: :ok

  defp validate_typed_value!(@value_type_u16, v, _field)
       when is_integer(v) and v >= 0 and v <= 0xFFFF,
       do: :ok

  defp validate_typed_value!(@value_type_fixed32, v, _field)
       when is_integer(v) and v >= -0x8000_0000 and v <= 0x7FFF_FFFF,
       do: :ok

  defp validate_typed_value!(@value_type_enum8, v, _field)
       when is_integer(v) and v >= 0 and v <= 0xFF,
       do: :ok

  defp validate_typed_value!(@value_type_bitset32, v, _field)
       when is_integer(v) and v >= 0 and v <= 0xFFFF_FFFF,
       do: :ok

  defp validate_typed_value!(value_type, v, field) do
    raise ArgumentError,
          "AttributeDefinition #{field} #{inspect(v)} out of range for value_type " <>
            "0x#{Integer.to_string(value_type, 16)}"
  end

  defp validate_min_default_max!(min_v, default_v, max_v) do
    if min_v > max_v do
      raise ArgumentError,
            "AttributeDefinition min_value (#{inspect(min_v)}) must be <= max_value " <>
              "(#{inspect(max_v)})"
    end

    if default_v < min_v or default_v > max_v do
      raise ArgumentError,
            "AttributeDefinition default_value (#{inspect(default_v)}) must lie in " <>
              "[min_value=#{inspect(min_v)}, max_value=#{inspect(max_v)}]"
    end

    :ok
  end

  defp validate_merge_rule!(rule)
       when rule in [
              @merge_override,
              @merge_add_delta,
              @merge_max,
              @merge_min,
              @merge_material_default
            ],
       do: :ok

  defp validate_merge_rule!(other),
    do:
      raise(
        ArgumentError,
        "unknown AttributeDefinition merge_rule tag #{inspect(other)} (expected 0x01..0x05)"
      )

  defp validate_dynamic!(true), do: true
  defp validate_dynamic!(false), do: false
  defp validate_dynamic!(1), do: true
  defp validate_dynamic!(0), do: false

  defp validate_dynamic!(other),
    do:
      raise(
        ArgumentError,
        "AttributeDefinition dynamic must be true/false or 0/1, got: #{inspect(other)}"
      )

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
