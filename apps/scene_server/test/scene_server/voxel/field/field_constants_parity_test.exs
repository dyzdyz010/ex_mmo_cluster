defmodule SceneServer.Voxel.Field.FieldConstantsParityTest do
  # 6.3 · field 物理常量单一来源(防漂移门禁)。
  #
  # 真相源:apps/scene_server/native/field_kernel/src/field_constants.rs。
  # Rust 四个 kernel `use crate::field_constants::*`;Elixir 四个 kernel 经
  # `SceneServer.Voxel.Field.Constants` 在编译期烘焙同一份数值。
  #
  # 本测试断言:
  #   1. Elixir `Constants` 解析出的每个常量值,与权威物理数值逐一一致
  #      ——任何人误改 `.rs` 里的数字都会在这里报红。
  #   2. `Constants` 解析出的常量集合恰为期望集合(无遗漏/无多余)
  #      ——防止常量被改名/删除/新增却没同步本门禁。
  #   3. Rust `field_constants.rs` 源文件里每个常量的字面量,与 `Constants`
  #      解析值一致——直接对照真相源文本,捕捉 Elixir 解析与 `.rs` 文本的任何分歧。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.Constants

  # 权威物理数值(Elixir 与 Rust 共享的全部 step-cost/ionization/温度/容差常量)。
  # 改动物理行为时,先改 field_constants.rs,再同步这张期望表。
  @expected %{
    # 电导 / 电势 step-cost 共享权重
    "DEFAULT_CONDUCTIVITY" => 0.0,
    "DEFAULT_DIELECTRIC_STRENGTH" => 3.0,
    "MIN_CONDUCTIVITY" => 0.001,
    "RESISTANCE_WEIGHT" => 4.0,
    "BREAKDOWN_WEIGHT" => 0.25,
    "IONIZATION_BONUS_WEIGHT" => 0.01,
    "MIN_STEP_COST" => 0.05,
    # ionization tick 演化
    "IONIZATION_THRESHOLD" => 50.0,
    "IONIZATION_GROWTH" => 5.0,
    "IONIZATION_DECAY" => 1.0,
    "IONIZATION_MAX" => 255.0,
    # 介质击穿放电 step-cost 权重
    "CONDUCTIVE_COST_WEIGHT" => 0.5,
    "DIELECTRIC_COST_WEIGHT" => 1.0,
    "IONIZATION_THRESHOLD_WEIGHT" => 0.05,
    "IONIZATION_COST_WEIGHT" => 0.01,
    # 温度扩散
    "TEMPERATURE_ALPHA_MAX" => 0.5,
    "FIXED32_SCALE" => 65_536.0,
    "DEFAULT_TC_RAW" => 6_554,
    "DEFAULT_DENSITY_RAW" => 65_536,
    "DEFAULT_SPECIFIC_HEAT_CAPACITY_RAW" => 65_536_000,
    "MIN_DENSITY_FLOAT" => 0.001,
    "MIN_SPECIFIC_HEAT_CAPACITY_FLOAT" => 0.001,
    # 数值容差
    "EPSILON" => 0.000001,
    "STALE_EPSILON" => 0.001
  }

  @rust_source Path.join(
                 __DIR__,
                 "../../../../native/field_kernel/src/field_constants.rs"
               )
               |> Path.expand()

  test "Constants 解析出恰好期望的常量集合(无遗漏/无多余)" do
    assert MapSet.new(Map.keys(Constants.all())) == MapSet.new(Map.keys(@expected))
  end

  test "Constants 每个常量值与权威物理数值一致" do
    for {name, expected_value} <- @expected do
      actual = Map.fetch!(Constants.all(), name)

      assert same_number?(actual, expected_value),
             "常量 #{name} 漂移:Constants=#{inspect(actual)} 期望=#{inspect(expected_value)}"

      # i64 常量必须保持整数类型,f64 常量必须保持浮点类型。
      assert is_integer(actual) == is_integer(expected_value),
             "常量 #{name} 类型漂移:Constants=#{inspect(actual)} 期望=#{inspect(expected_value)}"
    end
  end

  test "具名访问器与 all/0 返回值一致" do
    for {name, _value} <- @expected do
      fun = name |> String.downcase() |> String.to_atom()
      assert apply(Constants, fun, []) == Map.fetch!(Constants.all(), name)
    end
  end

  test "Rust field_constants.rs 源文本里的字面量与 Constants 解析值一致" do
    # 直接对照真相源文本:逐行抽取 `pub const NAME: f64|i64 = VALUE;`,
    # 与 Constants 解析值比对。捕捉 Elixir 解析逻辑与 .rs 文本之间的任何分歧。
    regex =
      ~r/^\s*pub\s+const\s+(?<name>[A-Z][A-Z0-9_]*)\s*:\s*(?<type>f64|i64)\s*=\s*(?<value>-?[0-9][0-9_]*(?:\.[0-9_]+)?)\s*;/

    parsed_from_rust =
      @rust_source
      |> File.read!()
      |> String.split(["\r\n", "\n"])
      |> Enum.flat_map(fn line ->
        case Regex.named_captures(regex, line) do
          nil ->
            []

          %{"name" => name, "type" => type, "value" => raw} ->
            digits = String.replace(raw, "_", "")

            value =
              case type do
                "f64" ->
                  if String.contains?(digits, "."),
                    do: String.to_float(digits),
                    else: String.to_float(digits <> ".0")

                "i64" ->
                  String.to_integer(digits)
              end

            [{name, value}]
        end
      end)
      |> Map.new()

    assert parsed_from_rust == Constants.all()
  end

  # f64/i64 混合比较:整数与浮点的同值比较用 ==,浮点之间允许极小误差。
  defp same_number?(a, b) when is_float(a) or is_float(b),
    do: abs(a * 1.0 - b * 1.0) < 1.0e-12

  defp same_number?(a, b), do: a == b
end
