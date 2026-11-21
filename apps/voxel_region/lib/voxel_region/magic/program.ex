defmodule VoxelRegion.Magic.Program do
  @moduledoc """
  全局系统功能（魔法）：咒语程序（IR v2，符号组合魔法 v2；目录 v5）在信任边界的唯一解析与校验。v1 JSON 程序已随
  切片 3 删除（决策稿 `2026-11-19-slice3-protocol.md` §6），线上只有 IR v2 一种表示。

  `decode_ir/2` 按设计 v2.6 §11.4（TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`）的文字规范
  解码二进制程序（字节层；签名层与计价层的分工见 §11.4.3 三层分工表）：大端；`version = 2`；`kind = 0` 为施法者动作（恰好 1 个 `caster_action` 符号），`kind = 1` 为
  结构组序列。每个结构组按固定段序（形成锚 → 参考锚 → 形 → 质 → 能 → 动 → 应）布局，Glyph = u16 目录下标 + 按
  目录槽序排列的槽字节。

  判定顺序：
  1. 长度：1 ≤ 字节数 ≤ 目录 `program_max_bytes`（目录加载时已保证 ≤ 512，即 min(目录值, 512)）；先判长度再解析。
  2. 布局与 §11.4.3 拒绝清单：版本、kind、各计数上限（目录值）、未知下标（含目录 `reserved_symbols` 中只预留未发布的
     下标，K3）、`in_program = false` 的下标（〈否〉）、
     段归属、段内与规则内按（下标，槽字节）严格升序、规则优先级依次为 0..n−1、`backup` 已开放、截断、尾随字节。
  3. 每个槽按 §11.4.2 的 B1 顺序：规范形式（`dec` 只认 e = 0 或 m ≥ 410，K1；枚举已发布；掩码位已发布；
     `ref8` 在 `refs_enabled = false` 时只能是 0xFF，其余值是否严格在前归签名层，S1/S4）→
     `zero_means_absent` 的 0 视为未写并结束 → 区间 → 依赖区间（`ranges_by_param`）→ 换算内部单位（能量 mJ）。
  4. 结构程序整体交给 `Magic.Signature.check/2`。

  对外只有一种失败 `{:error, :invalid_program}`；`diagnose_ir/2` 返回同一判定的可诊断原因（带字节偏移）。
  本模块不写日志：施法入口（`World.Casting`）用 `diagnose_ir/2` 的原因带上施法者与请求上下文写一条
  `voxel_magic_program_rejected`（决策稿 §8，一条拒绝只打一次，AGENTS 铁律 8）。
  通过后的 `%Program{}` 即合法程序，Cost 与 Structure 直接消费，不再复核。
  """

  alias VoxelRegion.Magic.Catalog.{Slot, Symbol}
  alias VoxelRegion.Magic.Signature

  defmodule Glyph do
    @moduledoc """
    已解码的一个符号实例。`params` 以槽的 `key` 为键（见 `Catalog.Slot`）：能量为整数 mJ（`*_mj`），其余为槽单位
    整数；枚举为已发布的枚举名；`ref8` 的 0xFF 与 `zero_means_absent` 的“未写”为 `nil`。
    """
    @enforce_keys [:index, :id, :params]
    defstruct [:index, :id, :params]
    @type t :: %__MODULE__{index: non_neg_integer(), id: String.t(), params: %{String.t() => term()}}
  end

  defmodule Rule do
    @moduledoc """
    应段的一条规则（设计 §11.4.1）：`priority` 与它在组内的序号相同；`backup` 为 `:none`、`:unmet`（未满足）或
    `:undecidable`（无法判定），非 `:none` 时 `backup_response` 是〈否〉内联执行的响应。
    """
    defstruct [:priority, :backup, :backup_response, readings: [], responses: []]
    @type t :: %__MODULE__{}
  end

  defmodule Group do
    @moduledoc "一个结构组：恰好 1 个形成锚，加六个段（各为按规范顺序排列的 `Glyph` 列表）与规则列表。"
    @enforce_keys [:form_anchor]
    defstruct [:form_anchor, ref_anchors: [], shape: [], quality: [], energy: [], motion: [], rules: []]
    @type t :: %__MODULE__{}
  end

  @typedoc """
  合法程序。`kind: :caster_action` 时 `action` 是唯一的施法者动作；`kind: :structure` 时 `groups` 按字节顺序
  排列（组序有语义：建构顺序与跨组引用）。`bytes` 是规范字节本身，其哈希可直接作为模板身份（§11.4.3 推论）。
  """
  @type t :: %__MODULE__{kind: :caster_action | :structure, action: Glyph.t() | nil, groups: [Group.t()], bytes: binary()}
  defstruct [:kind, :action, :bytes, groups: []]

  @version 2
  # 解码器硬上限（设计 §11.4.1 N4、§11.4.3 第 8 条）；目录值只能更低，由 `Catalog` 在加载时保证。
  @hard_max_bytes 512
  @hard_counts %{n_act: 1, n_grp: 3, n_ref: 3, n_shape: 5, n_qual: 12, n_energy: 2, n_motion: 4, n_rule: 4,
    n_read: 2, n_resp: 2}
  @backup %{0 => :none, 1 => :unmet, 2 => :undecidable}

  @doc "解码器硬上限：程序字节数与 §11.4.1 的十个计数。目录 v5 的 `limits` 只能等于或低于它们。"
  def hard_limits, do: %{program_max_bytes: @hard_max_bytes, counts: @hard_counts}

  @doc """
  IR v2 程序字节 → `{:ok, %Program{}}` | `{:error, :invalid_program}`：`diagnose_ir/2` 的同一判定，丢掉原因，
  供只需要合法与否的调用方使用。
  """
  @spec decode_ir(binary(), VoxelRegion.Magic.Catalog.t()) :: {:ok, t()} | {:error, :invalid_program}
  def decode_ir(bytes, catalog) do
    case diagnose_ir(bytes, catalog) do
      {:ok, program} -> {:ok, program}
      {:error, _reason} -> {:error, :invalid_program}
    end
  end

  @doc """
  与 `decode_ir/2` 同一判定，失败时返回可诊断原因（偏移均为程序字节内的 0 起偏移）：

  - `{:too_long, size, limit}`；`{:truncated, offset}`；`{:trailing_bytes, offset}`
  - `{:version, value}`；`{:kind, offset, value}`；`{:count, offset, count_name, value}`
  - `{:unknown_index, offset, index}`；`{:not_in_program, offset, id}`；`{:section, offset, id, expected_section}`
  - `{:order, offset}`（段内或规则内未严格升序，offset 指向后一个 Glyph）；`{:priority, offset, value}`；
    `{:backup_mode, offset, value}`
  - 槽：`{:noncanonical_dec, offset, slot}`、`{:unpublished_enum, offset, slot, code}`、
    `{:unpublished_bits, offset, slot, bits}`、`{:ref_disabled, offset, slot, value}`、
    `{:out_of_range, offset, slot, value}`、`{:dependent_range, offset, slot, value}`（value 以槽单位计）
  - `{:signature, [Signature.violation]}`
  """
  @spec diagnose_ir(binary(), VoxelRegion.Magic.Catalog.t()) :: {:ok, t()} | {:error, term()}
  def diagnose_ir(bytes, catalog) when is_binary(bytes) do
    limit = catalog.limits.program_max_bytes

    with :ok <- expect(byte_size(bytes) <= limit, {:too_long, byte_size(bytes), limit}),
         {:ok, program} <- program({bytes, 0}, catalog),
         :ok <- signature(program, catalog) do
      {:ok, %{program | bytes: bytes}}
    end
  end

  # ---- 程序与结构组布局（§11.4.1）----

  defp program(cursor, catalog) do
    with {:ok, version, cursor} <- u8(cursor),
         :ok <- expect(version == @version, {:version, version}),
         {:ok, kind, cursor} <- u8(cursor),
         {:ok, program, cursor} <- body(kind, cursor, catalog),
         :ok <- finished(cursor) do
      {:ok, program}
    end
  end

  defp body(0, cursor, catalog) do
    with {:ok, _one, cursor} <- count(cursor, :n_act, 1, catalog),
         {:ok, {action, _key, _at}, cursor} <- glyph(cursor, :caster_action, catalog) do
      {:ok, %__MODULE__{kind: :caster_action, action: action}, cursor}
    end
  end

  defp body(1, cursor, catalog) do
    with {:ok, n, cursor} <- count(cursor, :n_grp, 1, catalog),
         {:ok, groups, cursor} <- repeat(n, cursor, &group(&1, catalog)) do
      {:ok, %__MODULE__{kind: :structure, groups: groups}, cursor}
    end
  end

  defp body(kind, {_, at}, _catalog), do: {:error, {:kind, at - 1, kind}}

  defp group(cursor, catalog) do
    with {:ok, {anchor, _key, _at}, cursor} <- glyph(cursor, :form_anchor, catalog),
         {:ok, ref_anchors, cursor} <- segment(cursor, :n_ref, :ref_anchor, catalog),
         {:ok, shape, cursor} <- segment(cursor, :n_shape, :shape, catalog),
         {:ok, quality, cursor} <- segment(cursor, :n_qual, :quality, catalog),
         {:ok, energy, cursor} <- segment(cursor, :n_energy, :energy, catalog),
         {:ok, motion, cursor} <- segment(cursor, :n_motion, :motion, catalog),
         {:ok, n, cursor} <- count(cursor, :n_rule, 0, catalog),
         {:ok, rules, cursor} <- rules(0, n, cursor, catalog, []) do
      {:ok,
       %Group{form_anchor: anchor, ref_anchors: ref_anchors, shape: shape, quality: quality, energy: energy,
         motion: motion, rules: rules}, cursor}
    end
  end

  # 规则：priority 必须等于序号；读数、响应各自规范有序；backup 须已开放，非 0 时内联 1 个响应（B2）。
  defp rules(n, n, cursor, _catalog, acc), do: {:ok, Enum.reverse(acc), cursor}

  defp rules(priority, n, {_, at} = cursor, catalog, acc) do
    with {:ok, value, cursor} <- u8(cursor),
         :ok <- expect(value == priority, {:priority, at, value}),
         {:ok, readings, cursor} <- segment(cursor, :n_read, :reading, catalog),
         {:ok, responses, {_, backup_at} = cursor} <- segment(cursor, :n_resp, :response, catalog),
         {:ok, mode, cursor} <- u8(cursor),
         :ok <- expect(mode in catalog.limits.backup_modes, {:backup_mode, backup_at, mode}),
         {:ok, backup_response, cursor} <- backup_response(mode, cursor, catalog) do
      rule = %Rule{priority: priority, readings: readings, responses: responses, backup: @backup[mode],
        backup_response: backup_response}

      rules(priority + 1, n, cursor, catalog, [rule | acc])
    end
  end

  defp backup_response(0, cursor, _catalog), do: {:ok, nil, cursor}

  defp backup_response(_mode, cursor, catalog) do
    with {:ok, {glyph, _key, _at}, cursor} <- glyph(cursor, :response, catalog), do: {:ok, glyph, cursor}
  end

  # 段：u8 计数 + Glyph × n；按（下标，槽字节）严格升序，完全相同的重复项同样拒绝（§11.4.3 第 2、4 条）。
  # 同一下标能否多次出现由签名的 `max_per_group` / `max_per_rule` 判定。
  defp segment(cursor, count_name, section, catalog) do
    with {:ok, n, cursor} <- count(cursor, count_name, 0, catalog),
         {:ok, entries, cursor} <- repeat(n, cursor, &glyph(&1, section, catalog)),
         :ok <- ascending(entries) do
      {:ok, Enum.map(entries, fn {glyph, _key, _at} -> glyph end), cursor}
    end
  end

  defp ascending(entries) do
    entries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:ok, fn [{_, previous, _}, {_, key, at}] -> if previous >= key, do: {:error, {:order, at}} end)
  end

  defp count({_, at} = cursor, name, min, catalog) do
    with {:ok, n, cursor} <- u8(cursor) do
      if n >= min and n <= catalog.limits.counts[name], do: {:ok, n, cursor}, else: {:error, {:count, at, name, n}}
    end
  end

  # ---- Glyph 与参数槽（§11.4.2）----

  # 返回 {glyph, 排序键 {下标, 槽字节}, 偏移}；排序键只用于规范顺序检查。
  defp glyph({_, at} = cursor, section, catalog) do
    with {:ok, index, cursor} <- u16(cursor),
         {:ok, symbol} <- published(catalog, index, at),
         :ok <- expect(symbol.in_program, {:not_in_program, at, symbol.id}),
         :ok <- expect(symbol.section == section, {:section, at, symbol.id, section}),
         {:ok, raw, cursor} <- take(cursor, slots_width(symbol)),
         {:ok, params} <- params(symbol, raw, at + 2) do
      {:ok, {%Glyph{index: index, id: symbol.id, params: params}, {index, raw}, at}, cursor}
    end
  end

  defp published(catalog, index, at) do
    case Map.fetch(catalog.symbols, index) do
      {:ok, symbol} -> {:ok, symbol}
      :error -> {:error, {:unknown_index, at, index}}
    end
  end

  # B1 第 1–3 步逐槽进行；第 4 步要用同一符号的枚举槽，放在全部槽读出之后；第 5 步最后换算。
  defp params(%Symbol{} = symbol, raw, at) do
    with {:ok, values} <- read_slots(symbol.params, raw, at, []),
         :ok <- dependent_ranges(symbol, values) do
      {:ok, Map.new(values, fn {slot, value, _at} -> {slot.key, internal(slot, value)} end)}
    end
  end

  defp read_slots([], <<>>, _at, acc), do: {:ok, Enum.reverse(acc)}

  defp read_slots([slot | rest], raw, at, acc) do
    width = width(slot.class)
    {bytes, raw} = :erlang.split_binary(raw, width)

    with {:ok, value} <- canonical(slot, bytes, at),
         {:ok, value} <- absent_or_in_range(slot, value, at) do
      read_slots(rest, raw, at + width, [{slot, value, at} | acc])
    end
  end

  # 第 1 步：规范形式。
  defp canonical(%Slot{class: :dec} = slot, <<e::4, m::12>>, at) do
    # e > 0 时须 m ≥ 410，否则存在更小的 e（§11.4.2）。Elixir 整数无上限，m × 10^e 不会溢出。
    if e == 0 or m >= 410, do: {:ok, m * 10 ** e}, else: {:error, {:noncanonical_dec, at, slot.name}}
  end

  defp canonical(%Slot{class: :lin16}, <<value::16>>, _at), do: {:ok, value}
  defp canonical(%Slot{class: :u8}, <<value>>, _at), do: {:ok, value}

  defp canonical(%Slot{class: :enum8} = slot, <<code>>, at) do
    case Map.fetch(slot.enum, code) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {:unpublished_enum, at, slot.name, code}}
    end
  end

  defp canonical(%Slot{class: :mask8} = slot, <<bits>>, at) do
    published = Enum.reduce(Map.keys(slot.bits), 0, &Bitwise.bor(&2, Bitwise.bsl(1, &1)))
    unpublished = Bitwise.band(bits, Bitwise.bnot(published))
    if unpublished == 0, do: {:ok, bits}, else: {:error, {:unpublished_bits, at, slot.name, unpublished}}
  end

  defp canonical(%Slot{class: :ref8}, <<0xFF>>, _at), do: {:ok, nil}
  defp canonical(%Slot{class: :ref8, refs_enabled: true}, <<value>>, _at), do: {:ok, value}
  defp canonical(%Slot{class: :ref8} = slot, <<value>>, at), do: {:error, {:ref_disabled, at, slot.name, value}}

  # 第 2、3 步：`zero_means_absent` 的 0 为“未写”，跳过区间检查并结束；否则按槽自身区间检查（槽单位）。
  defp absent_or_in_range(%Slot{zero_means_absent: true}, 0, _at), do: {:ok, nil}
  defp absent_or_in_range(%Slot{min: nil}, value, _at), do: {:ok, value}

  defp absent_or_in_range(%Slot{min: min, max: max} = slot, value, at) do
    if value >= min and value <= max, do: {:ok, value}, else: {:error, {:out_of_range, at, slot.name, value}}
  end

  # 第 4 步：依赖区间。按枚举槽的取值查目录表，对目录数据做通用解释（“须为 0”即 [0, 0]）；“未写”的槽已在第 2 步结束。
  defp dependent_ranges(symbol, values) do
    by_name = Map.new(values, fn {slot, value, at} -> {slot.name, {value, at}} end)

    Enum.find_value(symbol.ranges_by_param, :ok, fn {param, by_value} ->
      {choice, _} = by_name[param]

      Enum.find_value(by_value[choice], fn {name, {min, max}} ->
        case by_name[name] do
          {nil, _} -> nil
          {value, at} when value < min or value > max -> {:error, {:dependent_range, at, name, value}}
          _ -> nil
        end
      end)
    end)
  end

  # 第 5 步：换算为内部单位（能量为整数 mJ，其余倍数为 1）。
  defp internal(%Slot{scale: scale}, value) when is_integer(value), do: value * scale
  defp internal(_slot, value), do: value

  defp slots_width(symbol), do: Enum.reduce(symbol.params, 0, &(width(&1.class) + &2))

  defp width(class) when class in [:dec, :lin16], do: 2
  defp width(class) when class in [:u8, :enum8, :mask8, :ref8], do: 1

  # ---- 签名 ----

  defp signature(%__MODULE__{kind: :caster_action}, _catalog), do: :ok

  defp signature(%__MODULE__{groups: groups}, catalog) do
    case Signature.check(groups, catalog) do
      :ok -> :ok
      {:error, violations} -> {:error, {:signature, violations}}
    end
  end

  # ---- 字节游标：{剩余字节, 当前偏移} ----

  defp u8({<<value, rest::binary>>, at}), do: {:ok, value, {rest, at + 1}}
  defp u8({<<>>, at}), do: {:error, {:truncated, at}}

  defp u16({<<value::16, rest::binary>>, at}), do: {:ok, value, {rest, at + 2}}
  defp u16({rest, at}), do: {:error, {:truncated, at + byte_size(rest)}}

  defp take({bytes, at}, n) when byte_size(bytes) >= n do
    {head, rest} = :erlang.split_binary(bytes, n)
    {:ok, head, {rest, at + n}}
  end

  defp take({bytes, at}, _n), do: {:error, {:truncated, at + byte_size(bytes)}}

  defp finished({<<>>, _at}), do: :ok
  defp finished({_, at}), do: {:error, {:trailing_bytes, at}}

  defp repeat(n, cursor, fun), do: repeat(n, cursor, fun, [])
  defp repeat(0, cursor, _fun, acc), do: {:ok, Enum.reverse(acc), cursor}

  defp repeat(n, cursor, fun, acc) do
    with {:ok, item, cursor} <- fun.(cursor), do: repeat(n - 1, cursor, fun, [item | acc])
  end

  defp expect(true, _reason), do: :ok
  defp expect(false, reason), do: {:error, reason}
end
