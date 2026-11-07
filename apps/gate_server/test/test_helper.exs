# 仓库根目录的 .env（见 .env.example，git 忽略）只补进程环境里没有的变量；没有这个文件就什么都不做。
with {:ok, text} <- File.read(Path.expand("../../../.env", __DIR__)) do
  for line <- String.split(text, ["
", "
"]),
      [key, value] <- [String.split(line, "=", parts: 2)],
      not String.starts_with?(key, "#") and value != "" and System.get_env(key) == nil,
      do: System.put_env(String.trim(key), String.trim(value))
end

ExUnit.start(assert_receive_timeout: 1_000)
Code.require_file("../../data_service/test/support/database.exs", __DIR__)
Code.require_file("../../scene_server/test/support/body_store.exs", __DIR__)
