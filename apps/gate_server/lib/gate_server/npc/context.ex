defmodule GateServer.Npc.Context do
  @moduledoc "全局系统功能：父脑与技能共享的模型输入投影；参数由权威 profile 提供，不拥有世界状态。"

  @doc "身体尺寸与运动能力，字段显式标注单位；不把模拟器参数当作已开放动作。"
  def body(profile) do
    %{height_m: 2 * profile.half_height, half_height_m: profile.half_height,
      radius_m: profile.radius, diameter_m: 2 * profile.radius,
      walk_speed_m_s: profile.speed, acceleration_m_s2: profile.acceleration,
      braking_m_s2: profile.braking, step_height_m: profile.step_height,
      design_clearance_micro: ceil(2 * profile.half_height * VoxelRegion.Spatial.micro_resolution()),
      move_to: %{can_jump: false, enters_liquid: false,
        max_step_macro: floor(profile.step_height), clearance_macro: ceil(2 * profile.half_height),
        refined_cells: :blocked_by_current_macro_navigation}}
  end

  @doc "所有决策入口共用的坐标约定。"
  def coordinates do
    %{up: :Y, horizontal: [:X,:Z], position_unit: :metre, position_origin: :body_center,
      micro_per_metre: VoxelRegion.Spatial.micro_resolution(),
      check_points: :world_micro_feet, draft_cells: :local_coordinates,
      feet_y: "position.y - body.half_height_m"}
  end
end
