defmodule SceneServer.Native.VoximMovement do
  @moduledoc """
  M1 在线共享运动内核的精确 POD tuple 接口。

  Scene 唯一持有可变 world；Gate 不接收 resource。角色状态完全来自每次参数，
  本模块不保存第二份积分状态，不解网络 bytes，也不读取资产和材质。
  profile/state/operation tuple 顺序以 Voxim Docs/M1/plan.md §2.8 为准。
  """
  use Rustler, otp_app: :scene_server, crate: "voxim_movement_nif"

  @doc "创建空的派生碰撞世界。"
  def new_world(), do: :erlang.nif_error(:nif_not_loaded)
  @doc "按唯一 coord 升序安装完整事务，DirtyCpu 中仅刷新一次 BVH。"
  def set_chunks(_world, _operations), do: :erlang.nif_error(:nif_not_loaded)
  @doc "按 entity_id 升序以 1/60 秒各推进一次，返回同序完整状态。"
  def step_characters(_world, _profile, _characters), do: :erlang.nif_error(:nif_not_loaded)
  @doc "返回共享内核本步查询的保守米制 AABB。"
  def query_bounds(_profile, _state), do: :erlang.nif_error(:nif_not_loaded)
  @doc "沿 probe 下扫至 min_center_y，首个接触合法才返回出生状态。"
  def find_spawn(_world, _profile, _probe, _min_center_y), do: :erlang.nif_error(:nif_not_loaded)
end
