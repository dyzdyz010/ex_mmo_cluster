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
    base =
      case Skill.fetch(profile.skill_id) do
        {:ok, skill} -> skill
        {:error, _} -> Skill.fetch(101) |> elem(1)
      end

    %Skill{
      base
      | id: profile.skill_id,
        name: profile.name,
        cooldown_ms: profile.skill_cooldown_ms,
        range: profile.skill_radius,
        effects: Enum.map(base.effects, fn effect -> %{effect | damage: profile.skill_damage} end)
    }
  end
end
