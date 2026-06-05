defmodule SceneServer.Voxel.CatalogPatch do
  @moduledoc """
  Catalog patch envelope (Phase 1.4)。

  Phase 1.4 只实现 wire envelope（opcode `0x71`），payload 保持 raw binary 以支持
  forward-compat skip。Phase 5 引入 `AttributeDefinition` / `TagDefinition` 时再
  解释 payload 字节内容。

  设计草案：`docs/plans/2026-05-13-phase1-catalog-patch-minimum.md`
  （P-1..P-3 全部推荐方案，用户 2026-05-13 approve）。

  **opcode 槽位**：设计草案推荐 `0x6F`，但与生产代码现有 `VoxelDebugProbe`
  冲突；用户改判 `0x71`（voxel 段扩展到 `0x70..0x7F`）。Phase 1.4 commit 只动
  scene 侧 envelope encode / decode + 协议规范追加 opcode 数值；gate codec
  集成、客户端 decoder 留给 Phase 5。

  Wire layout (一旦发出即冻结)：

      schema_kind: u8          # 0x01 attribute / 0x02 tag / 0x03..0xFF reserved
      base_version: u64        # patch 适用的 catalog 基线版本
      new_version: u64         # patch 完成后的 catalog 新版本
      op_count: u16
      ops[op_count] {
        op_kind: u8            # 0x01 add / 0x02 remove / 0x03 update
        entry_id: u32          # attribute_id / tag_id
        payload_len: u16       # forward-compat: 让 decoder skip unknown op_kind
        payload: bytes(payload_len)
      }

  Phase 1.4 不解释 payload 字节内容。

  Forward-compat 策略：
    * 未知 `op_kind`：decoder 保留数值 + payload raw binary（不 raise）。
      Re-encode 是 byte-identical pass-through，让中间路由节点可以转发未来
      catalog op 而不需 schema 升级。
    * 未知 `schema_kind`：decoder 硬错误（`{:error, :unknown_schema_kind}`）。
      schema_kind 是 envelope 级 dispatch tag，未知值意味着协议演进，必须
      bump opcode 或更高层处理，不能静默吞掉。

  Ops 列表内**不**强制按 entry_id 排序：catalog patch 是顺序应用，order
  matters。与 `AttributeSet` / `TagSet` 的 canonical 池重排不同。
  """

  @schema_attribute 0x01
  @schema_tag 0x02

  @op_add 0x01
  @op_remove 0x02
  @op_update 0x03

  @max_u16 0xFFFF
  @max_u32 0xFFFF_FFFF
  @max_u64 0xFFFF_FFFF_FFFF_FFFF

  defstruct schema_kind: @schema_attribute,
            base_version: 0,
            new_version: 0,
            ops: []

  @type op_kind :: 0..0xFF
  @type op :: %{
          required(:op_kind) => op_kind,
          required(:entry_id) => 0..0xFFFF_FFFF,
          required(:payload) => binary()
        }
  @type t :: %__MODULE__{
          schema_kind: 0x01 | 0x02,
          base_version: 0..0xFFFF_FFFF_FFFF_FFFF,
          new_version: 0..0xFFFF_FFFF_FFFF_FFFF,
          ops: [op]
        }

  # ---- public schema/op-kind helpers -----------------------------------------

  @doc "schema_kind tag for attribute catalog (0x01)."
  @spec schema_attribute() :: 0x01
  def schema_attribute, do: @schema_attribute

  @doc "schema_kind tag for tag catalog (0x02)."
  @spec schema_tag() :: 0x02
  def schema_tag, do: @schema_tag

  @doc "op_kind tag for `add` (0x01)."
  @spec op_add() :: 0x01
  def op_add, do: @op_add

  @doc "op_kind tag for `remove` (0x02)."
  @spec op_remove() :: 0x02
  def op_remove, do: @op_remove

  @doc "op_kind tag for `update` (0x03)."
  @spec op_update() :: 0x03
  def op_update, do: @op_update

  # ---- constructors / normalize ----------------------------------------------

  @doc "Builds and validates a CatalogPatch from keyword / map input."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))
  def new(attrs) when is_map(attrs), do: normalize!(attrs)

  @doc """
  Normalizes a CatalogPatch (or compatible map). Validates `schema_kind`,
  version monotonicity, each op's `op_kind` / `entry_id` / `payload` fields,
  and `payload_len` ≤ u16. Raises `ArgumentError` on any violation.

  Note: ops are **not** sorted — catalog patch ops are sequentially applied
  and order matters.
  """
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = patch) do
    patch
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    schema_kind = fetch(attrs, :schema_kind, @schema_attribute)
    base_version = fetch(attrs, :base_version, 0)
    new_version = fetch(attrs, :new_version, 0)
    raw_ops = fetch(attrs, :ops, [])

    validate_schema_kind_strict!(schema_kind)
    validate_u64!(base_version, :base_version)
    validate_u64!(new_version, :new_version)

    if base_version > new_version do
      raise ArgumentError,
            "CatalogPatch version must be monotonic: base_version (#{base_version}) " <>
              "must be <= new_version (#{new_version})"
    end

    unless is_list(raw_ops) do
      raise ArgumentError, "CatalogPatch ops must be a list, got: #{inspect(raw_ops)}"
    end

    if length(raw_ops) > @max_u16 do
      raise ArgumentError,
            "CatalogPatch op_count #{length(raw_ops)} exceeds u16 range (#{@max_u16})"
    end

    ops = Enum.map(raw_ops, &normalize_op_strict!/1)

    %__MODULE__{
      schema_kind: schema_kind,
      base_version: base_version,
      new_version: new_version,
      ops: ops
    }
  end

  # ---- wire encode ------------------------------------------------------------

  @doc """
  Encodes the patch into its wire layout (envelope + ops). Validates struct
  fields at the wire boundary; unknown op_kind values are accepted here on the
  encode side **only** to support the forward-compat pass-through
  (decode → preserve unknown → re-encode byte-identical).
  """
  @spec encode_for_wire(t() | map()) :: binary()
  def encode_for_wire(%__MODULE__{} = patch) do
    do_encode_for_wire(patch)
  end

  def encode_for_wire(attrs) when is_map(attrs) do
    attrs
    |> normalize!()
    |> do_encode_for_wire()
  end

  defp do_encode_for_wire(%__MODULE__{
         schema_kind: schema_kind,
         base_version: base_version,
         new_version: new_version,
         ops: ops
       }) do
    # Envelope-level guards: ALL writes to the wire must satisfy schema_kind
    # whitelist + version monotonic + op_count u16.  (normalize!/1 already
    # validates these on the typed-construction path; this branch defends the
    # case where the caller constructs a raw %CatalogPatch{} directly.)
    validate_schema_kind_strict!(schema_kind)
    validate_u64!(base_version, :base_version)
    validate_u64!(new_version, :new_version)

    if base_version > new_version do
      raise ArgumentError,
            "CatalogPatch version must be monotonic on encode: base (#{base_version}) " <>
              "> new (#{new_version})"
    end

    op_count = length(ops)

    if op_count > @max_u16 do
      raise ArgumentError,
            "CatalogPatch op_count #{op_count} exceeds u16 range (#{@max_u16})"
    end

    iodata = [
      <<schema_kind::unsigned-big-integer-size(8)>>,
      <<base_version::unsigned-big-integer-size(64)>>,
      <<new_version::unsigned-big-integer-size(64)>>,
      <<op_count::unsigned-big-integer-size(16)>>,
      Enum.map(ops, &encode_op_for_wire/1)
    ]

    IO.iodata_to_binary(iodata)
  end

  defp encode_op_for_wire(%{op_kind: op_kind, entry_id: entry_id, payload: payload})
       when is_integer(op_kind) and op_kind >= 0 and op_kind <= 0xFF and
              is_integer(entry_id) and entry_id >= 0 and entry_id <= @max_u32 and
              is_binary(payload) do
    payload_len = byte_size(payload)

    if payload_len > @max_u16 do
      raise ArgumentError,
            "CatalogPatch op payload_len #{payload_len} exceeds u16 range (#{@max_u16})"
    end

    [
      <<op_kind::unsigned-big-integer-size(8)>>,
      <<entry_id::unsigned-big-integer-size(32)>>,
      <<payload_len::unsigned-big-integer-size(16)>>,
      payload
    ]
  end

  defp encode_op_for_wire(other) do
    raise ArgumentError, "CatalogPatch op malformed for encode: #{inspect(other)}"
  end

  # ---- wire decode ------------------------------------------------------------

  @doc """
  Decodes a CatalogPatch envelope from `binary`. Returns `{:ok, %CatalogPatch{}}`
  on success or `{:error, atom}` on schema / framing errors.

  Forward-compat rule:
    * Unknown `op_kind` (0x04..0xFF) **is preserved** as raw `%{op_kind,
      entry_id, payload}` map (the payload stays opaque binary). Re-encoding
      such a decoded patch yields byte-identical wire output.
    * Unknown `schema_kind` returns `{:error, :unknown_schema_kind}` — this is
      an envelope-level dispatch tag and silently swallowing unknown values
      would corrupt the catalog stream.
  """
  @spec decode_for_wire(binary()) ::
          {:ok, t()} | {:error, :unknown_schema_kind | :malformed | :truncated}
  def decode_for_wire(<<
        schema_kind::unsigned-big-integer-size(8),
        base_version::unsigned-big-integer-size(64),
        new_version::unsigned-big-integer-size(64),
        op_count::unsigned-big-integer-size(16),
        rest::binary
      >>) do
    cond do
      not known_schema_kind?(schema_kind) ->
        {:error, :unknown_schema_kind}

      base_version > new_version ->
        {:error, :malformed}

      true ->
        case decode_ops(rest, op_count, []) do
          {:ok, ops, <<>>} ->
            {:ok,
             %__MODULE__{
               schema_kind: schema_kind,
               base_version: base_version,
               new_version: new_version,
               ops: ops
             }}

          {:ok, _ops, _trailing} ->
            {:error, :malformed}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def decode_for_wire(_), do: {:error, :truncated}

  @doc "Decodes a CatalogPatch envelope or raises `ArgumentError` on failure."
  @spec decode_for_wire!(binary()) :: t()
  def decode_for_wire!(binary) when is_binary(binary) do
    case decode_for_wire(binary) do
      {:ok, patch} ->
        patch

      {:error, :unknown_schema_kind} ->
        raise ArgumentError,
              "CatalogPatch decode: unknown schema_kind (envelope-level hard error)"

      {:error, reason} ->
        raise ArgumentError, "CatalogPatch decode failed: #{inspect(reason)}"
    end
  end

  # ---- internals: op decoding -------------------------------------------------

  defp decode_ops(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_ops(
         <<op_kind::unsigned-big-integer-size(8), entry_id::unsigned-big-integer-size(32),
           payload_len::unsigned-big-integer-size(16), rest::binary>>,
         remaining,
         acc
       )
       when remaining > 0 do
    if byte_size(rest) < payload_len do
      {:error, :truncated}
    else
      <<payload::binary-size(^payload_len), tail::binary>> = rest

      op = %{op_kind: op_kind, entry_id: entry_id, payload: payload}
      decode_ops(tail, remaining - 1, [op | acc])
    end
  end

  defp decode_ops(_other, _remaining, _acc), do: {:error, :truncated}

  # ---- internals: validation --------------------------------------------------

  defp validate_schema_kind_strict!(@schema_attribute), do: :ok
  defp validate_schema_kind_strict!(@schema_tag), do: :ok

  defp validate_schema_kind_strict!(other) do
    raise ArgumentError,
          "CatalogPatch schema_kind must be 0x01 (attribute) or 0x02 (tag); got: " <>
            inspect(other)
  end

  defp known_schema_kind?(@schema_attribute), do: true
  defp known_schema_kind?(@schema_tag), do: true
  defp known_schema_kind?(_), do: false

  defp validate_u64!(value, _field)
       when is_integer(value) and value >= 0 and value <= @max_u64,
       do: :ok

  defp validate_u64!(value, field) do
    raise ArgumentError,
          "CatalogPatch #{field} must be u64 (0..#{@max_u64}); got: #{inspect(value)}"
  end

  defp normalize_op_strict!(op) when is_map(op) do
    op_kind = fetch(op, :op_kind, nil)
    entry_id = fetch(op, :entry_id, nil)
    payload = fetch(op, :payload, <<>>)

    validate_op_kind_strict!(op_kind)
    validate_entry_id!(entry_id)
    validate_payload!(payload)

    %{op_kind: op_kind, entry_id: entry_id, payload: payload}
  end

  defp normalize_op_strict!(other) do
    raise ArgumentError, "CatalogPatch op must be a map, got: #{inspect(other)}"
  end

  defp validate_op_kind_strict!(@op_add), do: :ok
  defp validate_op_kind_strict!(@op_remove), do: :ok
  defp validate_op_kind_strict!(@op_update), do: :ok

  defp validate_op_kind_strict!(other) do
    raise ArgumentError,
          "CatalogPatch op_kind must be 0x01 (add), 0x02 (remove), or 0x03 (update) " <>
            "on normalize; got: #{inspect(other)} (unknown op_kind values are only " <>
            "tolerated during wire decode for forward-compat)"
  end

  defp validate_entry_id!(value)
       when is_integer(value) and value >= 0 and value <= @max_u32,
       do: :ok

  defp validate_entry_id!(other) do
    raise ArgumentError,
          "CatalogPatch op entry_id must be u32 (0..#{@max_u32}); got: #{inspect(other)}"
  end

  defp validate_payload!(value) when is_binary(value) do
    if byte_size(value) > @max_u16 do
      raise ArgumentError,
            "CatalogPatch op payload byte size #{byte_size(value)} exceeds u16 range (#{@max_u16})"
    end

    :ok
  end

  defp validate_payload!(other) do
    raise ArgumentError, "CatalogPatch op payload must be a binary; got: #{inspect(other)}"
  end

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
