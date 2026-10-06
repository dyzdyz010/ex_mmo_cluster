defmodule GateServer.Npc.Responses do
  @moduledoc """
  全局系统功能：OpenAI Responses 应答里工具调用的唯一解析处。模型输出是外部输入：参数不是合法 JSON 对象时
  显式标为 `{:error, :invalid_tool_arguments}`，没有 output 列表等同于没有工具调用；不因模型输出崩溃。
  父脑（`Brain.Llm`）、住宅设计会话与荒野施工的规划请求共用；各自只解释工具名的含义。
  """

  @type call :: %{
          call_id: String.t() | nil,
          name: String.t() | nil,
          arguments: {:ok, map()} | {:error, :invalid_tool_arguments}
        }

  @doc "按出现顺序列出应答里的 function_call；推理、文本等其他条目忽略。"
  @spec function_calls(term()) :: [call()]
  def function_calls(%{"output" => output}) when is_list(output) do
    for %{"type" => "function_call"} = item <- output do
      %{call_id: item["call_id"], name: item["name"], arguments: arguments(item["arguments"])}
    end
  end

  def function_calls(_), do: []

  defp arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = args} -> {:ok, args}
      _ -> {:error, :invalid_tool_arguments}
    end
  end

  defp arguments(_), do: {:error, :invalid_tool_arguments}
end
