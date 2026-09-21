# :live_llm 调用真实模型接口（NPC_LLM_URL / NPC_LLM_KEY / NPC_LLM_MODEL），只在显式 --include 时运行。
# :npc_scale 是多 NPC 成本测量（打印数字，约 1 分钟），只在显式 --include 时运行。
ExUnit.start(assert_receive_timeout: 1_000, exclude: [:live_llm, :npc_scale])
Code.require_file("../../data_service/test/support/database.exs", __DIR__)
Code.require_file("support/voxel_session.exs", __DIR__)
