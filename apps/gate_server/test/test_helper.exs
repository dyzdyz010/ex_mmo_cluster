# 仓库根目录的 .env（见 .env.example，git 忽略）只补进程环境里没有的变量；没有这个文件就什么都不做。
with {:ok, text} <- File.read(Path.expand("../../../.env", __DIR__)) do
  for line <- String.split(text, ["
", "
"]),
      [key, value] <- [String.split(line, "=", parts: 2)],
      not String.starts_with?(key, "#") and value != "" and System.get_env(key) == nil,
      do: System.put_env(String.trim(key), String.trim(value))
end

# :live_llm 调用真实模型接口（NPC_LLM_URL / NPC_LLM_KEY / NPC_LLM_MODEL），只在显式 --include 时运行。
# :npc_scale 是多 NPC 成本测量（打印数字，约 1 分钟），只在显式 --include 时运行。
ExUnit.start(assert_receive_timeout: 1_000, exclude: [:live_llm, :npc_scale])
Code.require_file("../../data_service/test/support/database.exs", __DIR__)
Code.require_file("support/voxel_session.exs", __DIR__)
