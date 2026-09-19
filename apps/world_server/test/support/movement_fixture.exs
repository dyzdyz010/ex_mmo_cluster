defmodule WorldServer.MovementFixture do
  @moduledoc "只测试：路由集成的独立磁盘世界与显式客户端资产依赖。"

  @doc "每个用例独占日志与生成缓存；复制参数后用当前 kernel 建新世界，不改发布清单。"
  def prepare do
    client = Path.expand("../../../../../Voxim", __DIR__)

    root =
      Path.join(
        System.tmp_dir!(),
        "movement_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    manifest = "Docs/R6/runtime/s4_worldgen_manifest.json"
    config = "Docs/M1/fixtures/demo-config.json"

    for relative <- [manifest, config] do
      target = Path.join([root, "Voxim", relative])
      File.mkdir_p!(Path.dirname(target))
      data = File.read!(Path.join(client, relative)) |> Jason.decode!()
      data = if relative == manifest, do: Map.delete(data, "content_version"), else: data
      File.write!(target, Jason.encode!(data))
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
