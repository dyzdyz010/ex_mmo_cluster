defmodule NpcServer.Secret do
  @moduledoc """
  全局系统功能：把模型 API key 这类敏感字符串包成闭包，让它随 profile / endpoint 在进程间流转时不以原文出现在
  进程状态、函数参数和崩溃报告里。

  ## 为什么

  NPC 的模型 endpoint（`url`、`key`、`model` …）随 profile 进入 Runtime、Brain、Life 的状态，以及选择 / 回合 / 技能
  worker 的参数。进程崩溃时，OTP 与 Elixir Logger 会把出错函数的参数、异常里携带的整项值（如 KeyError 打印的 map）、
  debug 级别下的 GenServer 状态整段写进 release 日志；VM 崩溃时还有 `erl_crash.dump`。key 若是原文字符串，就会随之进日志。

  依据：Erlang 生态基金会安全工作组《Protecting sensitive data》
  （https://security.erlef.org/secure_coding_and_deployment_hardening/sensitive_data）：

    * “Wrap sensitive data in a closure when passing it as an argument to a function”；
    * “Secrets wrapped in a closure are also safe from introspection using Observer and from being written to
      crash dumps.”

  同一篇另列的做法——为持有敏感数据的 gen_server 实现 `format_status`、为结构体实现或派生 `Inspect`、
  从堆栈里剪掉参数——都是在某一个输出口上打补丁；闭包在源头让 key 不以原文出现在任何项里，所以只用这一种。

  ## 契约

  信任边界（`NpcServer.Registry` 读运行环境）用 `wrap/1` 包一次；之后 endpoint 的 `key` 只有这一种形状，内部链路
  原样传递、不再判断。唯一的取出入口是 `reveal/1`，只在拼出站请求头的那一刻调用（`NpcServer.Http.request/2`）。
  闭包 `inspect` 出来是 `#Function<…>`，不带它捕获的值。

  不覆盖：取出之后的明文请求头会进 Finch / Mint 的在途请求（残余，见 `NpcServer.Http` 的 moduledoc）。
  """

  @opaque t :: (-> String.t())

  @doc "在信任边界把敏感字符串包成闭包。"
  @spec wrap(String.t()) :: t()
  def wrap(value) when is_binary(value), do: fn -> value end

  @doc "取出原文；只在拼出站请求头的那一刻调用（`NpcServer.Http.request/2`），取出的值不再存进任何状态。"
  @spec reveal(t()) :: String.t()
  def reveal(secret) when is_function(secret, 0), do: secret.()

  # 传进来的不是闭包（多半是直接拼 endpoint 时写了原文字符串）：显式失败且不回显。没有这一子句时是
  # FunctionClauseError，OTP 会把实参（原文 key）放进栈帧、打进崩溃报告。
  def reveal(_not_a_secret),
    do:
      raise(ArgumentError, "endpoint.key 必须是 NpcServer.Secret（用 NpcServer.Secret.wrap/1 包）；原值不回显")
end
