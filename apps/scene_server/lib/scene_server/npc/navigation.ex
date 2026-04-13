defmodule SceneServer.Npc.Navigation do
  alias SceneServer.Movement.{InputFrame, Profile, State}
  alias SceneServer.Npc.Profile, as: NpcProfile
  alias SceneServer.Npc.State, as: NpcState

  @arrival_epsilon 8.0

  @spec build_input_frame(
          NpcState.t(),
          State.t(),
          Profile.t(),
          NpcProfile.t(),
          {float(), float(), float()} | nil,
          non_neg_integer()
        ) :: InputFrame.t()
  def build_input_frame(
        %NpcState{} = npc_state,
        %State{} = movement_state,
        %Profile{} = movement_profile,
        %NpcProfile{} = npc_profile,
        target_position,
        seq
      ) do
    input_dir =
      case desired_target(npc_state.intent, target_position, npc_profile.spawn_position) do
        nil -> {0.0, 0.0}
        destination -> direction_towards(movement_state.position, destination)
      end

    movement_flags =
      if input_dir == {0.0, 0.0} do
        0b10
      else
        0
      end

    %InputFrame{
      seq: seq,
      client_tick: movement_state.tick + 1,
      dt_ms: movement_profile.fixed_dt_ms,
      input_dir: input_dir,
      speed_scale: npc_profile.movement_speed_scale,
      movement_flags: movement_flags
    }
  end

  @spec direction_towards({float(), float(), float()}, {float(), float(), float()}) ::
          {float(), float()}
  def direction_towards({x, y, _z}, {tx, ty, _tz}) do
    dx = tx - x
    dy = ty - y
    magnitude = :math.sqrt(dx * dx + dy * dy)

    if magnitude <= @arrival_epsilon do
      {0.0, 0.0}
    else
      {dx / magnitude, dy / magnitude}
    end
  end

  defp desired_target(:chase, target_position, _spawn_position), do: target_position
  defp desired_target(:return_home, _target_position, spawn_position), do: spawn_position
  defp desired_target(_intent, _target_position, _spawn_position), do: nil
end
