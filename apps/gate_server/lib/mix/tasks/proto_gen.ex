defmodule Mix.Tasks.ProtoGen do
  use Mix.Task

  def run(_args) do
    in_dir = File.cwd!() <> "//priv/proto"
    out_dir = File.cwd!() <> "/lib/gate_server/proto"
    System.shell("protoc --proto_path=#{in_dir} --elixir_out=#{out_dir} #{in_dir}/*.proto")
    # System.cmd("protoc", [
    #   "--proto_path=" <> in_dir,
    #   "--elixir_out=" <> out_dir,
    #   in_dir <> "/*.proto"
    # ])
  end
end
