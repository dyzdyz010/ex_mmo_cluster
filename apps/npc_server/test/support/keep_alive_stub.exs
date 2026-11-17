defmodule NpcServer.KeepAliveStub do
  @moduledoc """
  只测试：可保持连接、可并发应答的本地 HTTP 替身。

  与 `NpcServer.HttpStub` 的区别——那个替身每个响应都带 `Connection: close`、串行 accept，复现不了 keep-alive 的
  队头阻塞；本替身按 HTTP/1.1 保持连接（响应带 `Content-Length` 与 `Connection: keep-alive`），每条连接一个进程，
  所以一条连接上的慢请求不会挡住别的连接。它只替代对端，实际的 `:httpc` 与 JSON 编解码照常运行。

  每条连接上每收到一个请求，先向起它的测试进程发：

      {:http_request, conn, %{method: :get | :put | :post | :patch, path: 路径加查询串,
                              headers: %{小写的头名 => 值}, body: 解码后的 JSON 请求体 | nil}}

  其中 `conn` 是连接号（从 1 递增），测试据此断言"这个请求走上了另一条连接"。连接建立 / 关闭另发
  `{:conn_opened, conn}` / `{:conn_closed, conn}`。

  再调用 `handler.(conn, method, path, body)` 取 `{status, data}` 作应答：`data` 是 binary 时原样作响应体，
  否则编码成 JSON。handler 在自己那条连接的进程里运行，可以 `Process.sleep` 模拟慢服务。
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "起一个替身，返回它的根 URL（`http://127.0.0.1:<端口>`）。必须在测试进程里调用。"
  def start(handler) do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :http_bin,
        reuseaddr: true,
        backlog: 32
      ])

    {:ok, {_, port}} = :inet.sockname(listener)
    counter = :atomics.new(1, [])
    acceptor = spawn(fn -> accept(listener, owner, handler, counter) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(acceptor, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept(listener, owner, handler, counter) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        conn = :atomics.add_get(counter, 1, 1)
        pid = spawn(fn -> serve(socket, conn, owner, handler) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listener, owner, handler, counter)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, conn, owner, handler) do
    receive do
      :go -> :ok
    after
      1000 -> :ok
    end

    send(owner, {:conn_opened, conn})
    loop(socket, conn, owner, handler)
  end

  defp loop(socket, conn, owner, handler) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, {:http_request, method, {:abs_path, path}, _}} ->
        method = normalize(method, path)
        headers = headers(socket, %{})
        :ok = :inet.setopts(socket, packet: :raw)
        size = String.to_integer(Map.get(headers, "content-length", "0"))

        body =
          if size == 0,
            do: nil,
            else:
              with(
                {:ok, bytes} <- :gen_tcp.recv(socket, size, 5_000),
                do: Jason.decode!(bytes)
              )

        send(
          owner,
          {:http_request, conn, %{method: method, path: path, headers: headers, body: body}}
        )

        {status, data} = handler.(conn, method, path, body)
        bytes = if is_binary(data), do: data, else: Jason.encode!(data)

        :ok = :inet.setopts(socket, packet: :http_bin)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Response\r\nContent-Type: application/json\r\n" <>
            "Content-Length: #{byte_size(bytes)}\r\nConnection: keep-alive\r\n\r\n" <> bytes
        )

        loop(socket, conn, owner, handler)

      {:error, _} ->
        send(owner, {:conn_closed, conn})
        :gen_tcp.close(socket)
    end
  end

  # Erlang 的 HTTP 解析器只把标准方法解成原子，PATCH 以二进制 "PATCH" 给出；未知方法由路径兜底，测试里用不到。
  defp normalize(:GET, _), do: :get
  defp normalize(:PUT, _), do: :put
  defp normalize(:POST, _), do: :post
  defp normalize(:DELETE, _), do: :delete
  defp normalize("PATCH", _), do: :patch
  defp normalize(method, _), do: method

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
