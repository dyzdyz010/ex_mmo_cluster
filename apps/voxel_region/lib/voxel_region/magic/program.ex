defmodule VoxelRegion.Magic.Program do
  @moduledoc """
  全局系统功能（魔法增量 1）：咒语程序（Canonical Magic IR，JSON）在信任边界的唯一解析与校验。

  线格式 `{"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":<id>,"args":{<slot>:<number>}}]}`，
  字节数 ≤ 目录 `program_max_bytes`。增量 1 的执行器只接受 target.kind = "aim"、emit = "at_target"、恰好 1 步；
  符号必须在目录里，参数键恰为该符号的槽名，每个值是落在槽 [min, max] 内的数。
  任何不符都是同一个失败 `:invalid_program`（不扣能量）；通过后返回的值即合法程序，下游不再复核。
  """

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
  def validate(
        %{"v" => 1, "target" => %{"kind" => "aim"} = target, "emit" => "at_target", "steps" => [step]} = data,
        catalog
      )
      when map_size(data) == 4 and map_size(target) == 1 do
    with %{"sym" => sym, "args" => args} when map_size(step) == 2 and is_map(args) <- step,
         {:ok, symbol} <- Map.fetch(catalog.symbols, sym),
         true <- Enum.sort(Map.keys(args)) == Enum.sort(Map.keys(symbol.slots)),
         true <-
           Enum.all?(args, fn {name, value} ->
             {min, max} = symbol.slots[name]
             is_number(value) and value >= min and value <= max
           end) do
      {:ok, %{target: :aim, emit: :at_target, steps: [%{sym: sym, args: Map.new(args, fn {k, v} -> {k, v * 1.0} end)}]}}
    else
      _ -> {:error, :invalid_program}
    end
  end

  def validate(_, _), do: {:error, :invalid_program}
end
