defmodule SceneServer.Combat.CastRequest do
  @moduledoc """
  Normalized client/NPC skill-cast request.

  This struct separates *which skill is being cast* from *how the caster wants
  to target it*. The authoritative combat executor can then resolve the final
  target using current server-side state instead of trusting a client-supplied
  outcome.
  """

  @type vector :: {float(), float(), float()}
  @type target_mode :: :auto | :actor | :point

  @enforce_keys [:skill_id, :target_mode]
  defstruct [:skill_id, :target_mode, :target_cid, :target_position]

  @type t :: %__MODULE__{
          skill_id: pos_integer(),
          target_mode: target_mode(),
          target_cid: integer() | nil,
          target_position: vector() | nil
        }

  @doc """
  Builds a cast request that lets the executor choose the best target.
  """
  @spec auto(pos_integer()) :: t()
  def auto(skill_id), do: %__MODULE__{skill_id: skill_id, target_mode: :auto}

  @doc """
  Builds a cast request targeting a specific actor CID.
  """
  @spec actor(pos_integer(), integer()) :: t()
  def actor(skill_id, target_cid) when is_integer(target_cid) do
    %__MODULE__{skill_id: skill_id, target_mode: :actor, target_cid: target_cid}
  end

  @doc """
  Builds a cast request targeting a point in world space.
  """
  @spec point(pos_integer(), vector()) :: t()
  def point(skill_id, target_position) do
    %__MODULE__{skill_id: skill_id, target_mode: :point, target_position: target_position}
  end
end
