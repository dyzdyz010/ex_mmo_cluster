defmodule SceneServer.Npc.Brain do
  alias SceneServer.Npc.{Facts, Profile}

  @type decision ::
          {:idle, nil}
          | {:chase, integer()}
          | {:attack, integer()}
          | {:return_home, nil}
          | {:dead, nil}

  @spec decide(Facts.t(), Profile.t()) :: decision()
  def decide(%Facts{alive: false}, _profile), do: {:dead, nil}

  def decide(%Facts{} = facts, %Profile{} = profile) do
    cond do
      facts.target_cid != nil and facts.target_distance != nil and
          facts.target_distance <= profile.attack_range ->
        {:attack, facts.target_cid}

      facts.target_cid != nil and facts.target_distance != nil and
          facts.target_distance <= profile.aggro_radius ->
        {:chase, facts.target_cid}

      is_number(facts.distance_from_spawn) and facts.distance_from_spawn > profile.leash_radius ->
        {:return_home, nil}

      true ->
        {:idle, nil}
    end
  end
end
