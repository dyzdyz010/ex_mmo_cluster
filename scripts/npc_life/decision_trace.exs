# 只测试：仅在本轮独立 Demo 安装；请求体无 endpoint/key，只保存可复核决策输入与工具输出。
{:module, _} = Code.ensure_loaded(GateServer.Npc.Http)
parent = self()
tracer = spawn(fn ->
  true = Process.register(self(), :npc_long_horizon_trace)
  send(parent, {:trace_ready, self()})
  loop = fn loop, pending ->
    receive do
      {:trace, pid, :call, {GateServer.Npc.Http, :request, [_endpoint, body]}} ->
        row = %{at_ms: System.system_time(:millisecond), pid: inspect(pid), request: body}
        File.write!("/demo/long-horizon-started.jsonl", Jason.encode!(row) <> "\n", [:append])
        loop.(loop, Map.put(pending, pid, row))
      {:trace, pid, :return_from, {GateServer.Npc.Http, :request, 2}, result} ->
        row = Map.fetch!(pending, pid)
        summary = case result do
          {:ok, response} -> %{status: "ok", usage: response["usage"], calls: Enum.filter(response["output"] || [], &(&1["type"] == "function_call"))}
          {:error, _} -> %{status: "error"}
        end
        File.write!("/demo/long-horizon-requests.jsonl", Jason.encode!(Map.merge(row, Map.put(summary, :finished_at_ms, System.system_time(:millisecond)))) <> "\n", [:append])
        loop.(loop, Map.delete(pending, pid))
    end
  end
  loop.(loop, %{})
end)
receive do {:trace_ready, ^tracer} -> :ok after 5000 -> raise "trace initialization timeout" end
patterns = :erlang.trace_pattern({GateServer.Npc.Http, :request, 2}, [{:_, [], [{:return_trace}]}], [:global])
procs = :erlang.trace(:all, true, [:call, {:tracer, tracer}])
Jason.encode!(%{patterns: patterns, procs: procs})
