defmodule SceneServer.Voxel.Field.Constants do
  @moduledoc """
  Field 物理常量在 Elixir 侧的**唯一读取入口**。

  这些电导/电势/介质击穿/温度扩散权重常量的真相源是 Rust crate 里的
  `apps/scene_server/native/field_kernel/src/field_constants.rs`。本模块在
  **编译期**解析该文件的 `pub const NAME: TYPE = VALUE;` 行,把每个常量烘焙成
  本模块的函数返回值,供 Field 各 kernel 的 Elixir fallback 路径使用。

  ## 为什么在编译期从 `.rs` 读取,而不是从 NIF 读取

  Field kernel 的 Elixir 路径(`ElectricField` / `ConductionPathKernel` /
  `ElectricDischargeKernel` / `TemperatureField` 的 fallback)恰恰在 **NIF 不可用**
  时才运行。如果常量改为运行期从 NIF 读取,fallback 在 NIF 缺失时就拿不到常量,
  自相矛盾。把数值在编译期从同一份 `.rs` 文件烘焙进 BEAM,既消除了 Elixir 的硬编码
  副本,又让 fallback 完全自包含,且与 native 算出的数值逐位一致。

  ## 防漂移

  - 物理常量的**数值**只在 `field_constants.rs` 改;两侧编译期自动同步。
  - `@external_resource` 声明确保 `.rs` 文件变化时本模块会重新编译。
  - `field_constants_parity_test.exs` 断言本模块解析值与各 kernel 实际使用值一致,
    并断言能解析出全部期望常量,作为可执行的漂移门禁。

  本模块**只**承载在 Elixir 与 Rust 之间双份维护的物理权重常量;纯 Rust 内部的
  网格面编码常量(`FACE_*` 等)没有 Elixir 副本,不在此处。
  """

  @source_path Path.join(__DIR__, "../../../../native/field_kernel/src/field_constants.rs")
                |> Path.expand()

  # .rs 文件变化时触发本模块重新编译,保证编译期烘焙的数值始终与真相源一致。
  @external_resource @source_path

  # 编译期解析 `pub const NAME: TYPE = VALUE;`:
  #   - NAME 大写下划线
  #   - TYPE ∈ {f64, i64}(其余类型如网格面编码不在共享集中,忽略)
  #   - VALUE 十进制字面量,允许 `_` 数字分组、可选小数、可选前导负号
  @const_regex ~r/^\s*pub\s+const\s+(?<name>[A-Z][A-Z0-9_]*)\s*:\s*(?<type>f64|i64)\s*=\s*(?<value>-?[0-9][0-9_]*(?:\.[0-9_]+)?)\s*;/

  @parsed (
             @source_path
             |> File.read!()
             |> String.split(["\r\n", "\n"])
             |> Enum.flat_map(fn line ->
               case Regex.named_captures(@const_regex, line) do
                 nil ->
                   []

                 %{"name" => name, "type" => type, "value" => raw} ->
                   digits = String.replace(raw, "_", "")

                   value =
                     case type do
                       # f64 字面量可能写成整数形式(如 `255`),String.to_float 要求小数点,
                       # 因此对无小数点的 f64 值补 ".0";有小数点直接转。
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
           )

  @doc """
  返回从 `field_constants.rs` 解析出的全部共享常量 map(`name => value`)。

  name 为 Rust 常量名字符串(如 `"RESISTANCE_WEIGHT"`)。主要用于 parity 测试
  做全集断言;业务代码应优先用下面的具名函数。
  """
  @spec all() :: %{optional(String.t()) => number()}
  def all, do: @parsed

  # ---- 具名访问器(编译期烘焙;函数名 = .rs 常量名小写) -------------------
  #
  # 为每个解析出的常量生成一个零参函数,返回值在编译期烘焙为字面量。
  # 例如 `RESISTANCE_WEIGHT` → `resistance_weight/0`。业务代码应优先用这些
  # 具名访问器,而不是 `all/0` 的字符串 key。

  @doc false
  @spec __accessors__() :: [{atom(), number()}]
  def __accessors__ do
    Enum.map(@parsed, fn {rust_name, value} ->
      {rust_name |> String.downcase() |> String.to_atom(), value}
    end)
  end

  for {rust_name, value} <- @parsed do
    fun_name = String.to_atom(String.downcase(rust_name))
    def unquote(fun_name)(), do: unquote(value)
  end
end
