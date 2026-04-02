defmodule Mix.Tasks.ProtoGen do
  use Mix.Task

  @shortdoc "Generate Elixir modules from gate_server proto definitions"

  @proto_files [
    "priv/proto/Packet.proto",
    "priv/proto/Heartbeat.proto",
    "priv/proto/AuthRequest.proto",
    "priv/proto/EntityAction.proto",
    "priv/proto/ServerResponse.proto",
    "priv/proto/Reply.proto",
    "priv/proto/Types.proto",
    "priv/proto/BroadcastPlayerAction.proto"
  ]

  def run(_args) do
    maybe_prepend_local_protoc_to_path()

    Mix.Task.run("protox.generate", [
      "--output-path=lib/gate_server/proto/generated.ex",
      "--include-path=priv/proto"
      | @proto_files
    ])
  end

  defp maybe_prepend_local_protoc_to_path do
    repo_root = Path.expand("../..", File.cwd!())
    local_protoc_dir = Path.join([repo_root, ".tools", "protoc-34.1", "bin"])
    local_protoc = Path.join(local_protoc_dir, executable_name("protoc"))

    if File.exists?(local_protoc) do
      System.put_env("PATH", local_protoc_dir <> path_separator() <> System.get_env("PATH", ""))
    end
  end

  defp executable_name(base_name) do
    case :os.type() do
      {:win32, _} -> base_name <> ".exe"
      _ -> base_name
    end
  end

  defp path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end
end
