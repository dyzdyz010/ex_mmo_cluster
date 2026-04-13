defmodule SceneServer.Npc.Attack do
  alias SceneServer.Combat.Skill
  alias SceneServer.Npc.Profile

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
