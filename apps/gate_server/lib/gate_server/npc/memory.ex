defmodule GateServer.Npc.Memory do
  @moduledoc "全局系统功能：模型的持久化记忆工具；只读写 NpcMemory，不持有进程缓存，世界状态仍须现查。"

  @key_limit 128
  @text_limit 1500

  def tools do
    key=%{type: "string",minLength: 1,maxLength: @key_limit}
    [
      %{type: "function",name: "remember",description: "按键保存或覆盖长期记忆：计划、经历与约定。世界现状请重新查询。",
        parameters: %{type: "object",properties: %{key: key,text: %{type: "string",minLength: 1,maxLength: @text_limit}},
          required: ["key","text"],additionalProperties: false}},
      %{type: "function",name: "recall",description: "按键读取自己的长期记忆；不存在时明确返回 missing。",
        parameters: %{type: "object",properties: %{key: key},required: ["key"],additionalProperties: false}}
    ]
  end

  def command("remember",args,id) when is_map(args),
    do: %{id: id,verb: :remember,key: args["key"],text: args["text"]}
  def command("recall",args,id) when is_map(args),do: %{id: id,verb: :recall,key: args["key"]}
  def command(name,_,id) when name in ["remember","recall"],do: command(name,%{},id)
  def command(_,_,_),do: nil

  def execute(memory,cid,position,%{id: id,verb: verb}=command) do
    result=if valid?(command),do: storage(fn -> perform(memory,cid,position,command) end),
      else: {:error,:invalid_memory_arguments}

    case result do
      {:ok,data} -> %{id: id,verb: verb,status: :done,reason: nil,data: data}
      {:error,reason} -> %{id: id,verb: verb,status: :rejected,reason: reason,data: nil}
    end
  end

  def recent(memory,cid,limit \\ 5) do
    storage(fn ->
      events=Enum.map(memory.recent(cid,limit),fn event ->
        %{text: event.text,position: Tuple.to_list(event.place),at: DateTime.to_iso8601(event.at)}
      end)
      {:ok,events}
    end)
  end

  @doc "记录技能结束的事实经历；数据库不可用时显式返回错误。"
  def journal(memory,cid,text,position) do
    storage(fn ->
      case memory.journal(cid,text,position) do
        :ok -> {:ok,:recorded}
        {:error,reason} -> {:error,{:memory_unavailable,reason}}
      end
    end)
  end

  defp valid?(%{verb: :remember,key: key,text: text}),do: text?(key,@key_limit) and text?(text,@text_limit)
  defp valid?(%{verb: :recall,key: key}),do: text?(key,@key_limit)
  defp valid?(_),do: false
  defp text?(text,limit),do: is_binary(text) and String.length(text) in 1..limit

  defp perform(memory,cid,position,%{verb: :remember,key: key,text: text}) do
    body=%{"text"=>text,"position"=>Tuple.to_list(position)}
    case memory.put(cid,"note",key,body) do
      :ok -> {:ok,%{key: key,body: body}}
      {:error,reason} -> {:error,{:memory_unavailable,reason}}
    end
  end

  defp perform(memory,cid,_position,%{verb: :recall,key: key}) do
    case memory.get(cid,"note",key) do
      nil -> {:ok,%{key: key,missing: true}}
      %{}=body -> {:ok,%{key: key,body: body}}
      {:error,reason} -> {:error,{:memory_unavailable,reason}}
    end
  end

  # 只转换数据库不可用；程序缺陷继续抛出，错误结果不暴露SQL或连接参数。
  defp storage(fun) do
    try do
      fun.()
    rescue
      exception in [DBConnection.ConnectionError,Postgrex.Error] ->
        {:error,{:memory_unavailable,exception.__struct__}}
    catch
      :exit,_ -> {:error,{:memory_unavailable,:process_exit}}
    end
  end
end
