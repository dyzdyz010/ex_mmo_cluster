defmodule SceneServer.Npc.Attack do
  @moduledoc """
  Builds NPC-specific authoritative attack definitions from NPC profile data.

  This keeps NPC damage/radius/cooldown tuning out of the player-oriented skill
  lookup table while still reusing the shared `SceneServer.Combat.Skill` struct.
  """

  alias SceneServer.Combat.Skill
  alias SceneServer.Npc.Profile

  @doc """
  Converts an NPC profile into the skill struct used by authoritative hit logic.
  """
  @spec skill(Profile.t()) :: Skill.t()
  def skill(%Profile{} = profile) do
    %Skill{
      id: profile.skill_id,
      damage: profile.skill_damage,
      radius: profile.skill_radius,
      cooldown_ms: profile.skill_cooldown_ms
    }
  end
end
