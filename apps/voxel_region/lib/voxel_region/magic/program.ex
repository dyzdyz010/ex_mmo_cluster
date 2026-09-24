defmodule VoxelRegion.Magic.Program do
  @moduledoc """
  全局系统功能（魔法增量 1–2）：咒语程序（Canonical Magic IR，JSON）在信任边界的唯一解析与校验。

  线格式 `{"v":1,"target":{"kind":"aim"},"emit":<发出>,"steps":[{"sym":<id>,"args":{<slot>:<number>}}]}`，
  字节数 ≤ 目录 `program_max_bytes`。执行器接受的程序形态（符号序列 → 发出方式）：

  - `act.heat` / `energy.draw` / `act.dispel`：单步，emit = "at_target"（目标由眼睛射线或线上拟态 id 给出）；
  - `form.semblance`：单步，emit = "hand"，拟态静止在手边；
  - `form.semblance` + `act.throw`：emit = "hand"，拟态从手边沿眼睛方向运动学抛出。

  符号必须在目录里，参数键恰为该符号的槽名，每个值是落在槽 [min, max] 内的数，枚举槽（`integer`）取整数。
  任何不符都是同一个失败 `:invalid_program`（不扣能量）；通过后返回的值即合法程序，下游不再复核。
  """

  @shapes %{
    ["act.heat"] => {"at_target", :at_target},
    ["energy.draw"] => {"at_target", :at_target},
    ["act.dispel"] => {"at_target", :at_target},
    ["form.semblance"] => {"hand", :hand},
    ["form.semblance", "act.throw"] => {"hand", :hand}
  }

  @doc "程序字节 → `{:ok, program}` | `{:error, :invalid_program}`。"
  def parse(bytes, catalog) do
    with true <- byte_size(bytes) <= catalog.program_max_bytes,
         {:ok, data} <- Jason.decode(bytes) do
      validate(data, catalog)
    else
      _ -> {:error, :invalid_program}
    end
  end

  @doc "已解码 JSON 值 → 合法程序；目录预设与线上程序共用。"
  def validate(%{"v" => 1, "target" => %{"kind" => "aim"} = target, "emit" => emit, "steps" => steps} = data, catalog)
      when map_size(data) == 4 and map_size(target) == 1 and is_list(steps) do
    with true <- Enum.all?(steps, &(is_map(&1) and map_size(&1) == 2 and is_map(&1["args"]))),
         {^emit, emitted} <- Map.get(@shapes, Enum.map(steps, & &1["sym"])),
         true <- Enum.all?(steps, &valid_step?(&1, catalog)) do
      {:ok,
       %{target: :aim, emit: emitted,
         steps: Enum.map(steps, fn %{"sym" => sym, "args" => args} ->
           %{sym: sym, args: Map.new(args, fn {k, v} -> {k, v * 1.0} end)}
         end)}}
    else
      _ -> {:error, :invalid_program}
    end
  end

  def validate(_, _), do: {:error, :invalid_program}

  defp valid_step?(%{"sym" => sym, "args" => args}, catalog) do
    with {:ok, symbol} <- Map.fetch(catalog.symbols, sym),
         true <- Enum.sort(Map.keys(args)) == Enum.sort(Map.keys(symbol.slots)) do
      Enum.all?(args, fn {name, value} ->
        {min, max} = symbol.slots[name]

        is_number(value) and value >= min and value <= max and
          (name not in symbol.integer or value == trunc(value))
      end)
    else
      _ -> false
    end
  end
end
