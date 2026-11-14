defmodule NpcServer.HttpStub do
  @moduledoc """
  只测试：本地 `:gen_tcp` HTTP 替身，代替 NPC 适配器要访问的外部 HTTP 服务（Hindsight、写日记的模型网关）。
  `npc_hindsight_test` 与 `npc_reflection_writer_test` 共用。端口由 OS 分配，每个测试独占，测试结束时关闭；
  替身只替代对端，实际的 `:httpc` 与 JSON 编解码照常运行。

  每收到一个请求，先向起它的测试进程发 `{:http_request, request}`：

      %{method: :get | :put | :post | :patch, path: 路径加查询串,
        headers: %{小写的头名 => 值}, body: 解码后的 JSON 请求体，没有请求体为 nil}

  再调用 `handler.(method, path, body)` 取 `{status, data}` 作应答：`data` 是 binary 时原样作响应体
  （用来回放真实响应的原始字节），否则编码成 JSON。
  """
  import ExUnit.Callbacks, only: [on_exit: 1]
  import ExUnit.Assertions, only: [flunk: 1]

  @doc "起一个替身，返回它的根 URL（`http://127.0.0.1:<端口>`）。必须在测试进程里调用（请求消息发给调用者）。"
  def start(handler) do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    pid = spawn(fn -> accept(listener, owner, handler) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(pid, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  @doc "按到达次序取 `count` 个请求（形状见模块文档）；每个至多等 1 秒，等不到即判测试失败。"
  def requests(count),
    do:
      for(
        _ <- 1..count,
        do:
          receive do
            {:http_request, request} -> request
          after
            1000 -> flunk("missing HTTP request")
          end
      )

  defp accept(listener, owner, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, {:http_request, method, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0, 1000)

        # Erlang 的 HTTP 解析器只把标准方法解成原子，PATCH 以二进制 "PATCH" 给出。
        method = %{:GET => :get, :PUT => :put, :POST => :post, "PATCH" => :patch}[method]
        headers = headers(socket, %{})
        :ok = :inet.setopts(socket, packet: :raw)
        size = String.to_integer(Map.get(headers, "content-length", "0"))

        body =
          if size == 0,
            do: nil,
            else:
              with({:ok, bytes} <- :gen_tcp.recv(socket, size, 1000), do: Jason.decode!(bytes))

        send(owner, {:http_request, %{method: method, path: path, headers: headers, body: body}})
        {status, data} = handler.(method, path, body)
        bytes = if is_binary(data), do: data, else: Jason.encode!(data)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Response\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(bytes)}\r\nConnection: close\r\n\r\n" <>
            bytes
        )

        :gen_tcp.close(socket)
        accept(listener, owner, handler)

      {:error, :closed} ->
        :ok
    end
  end

  # 读完请求头；已知的头名解析器给原子（如 :"Content-Length"），其余给二进制，一律转成小写字符串。
  defp headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, :http_eoh} ->
        acc

      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, Map.put(acc, name |> to_string() |> String.downcase(), value))
    end
  end
end
