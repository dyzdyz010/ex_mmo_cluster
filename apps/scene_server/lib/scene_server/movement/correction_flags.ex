defmodule SceneServer.Movement.CorrectionFlags do
  @moduledoc """
  Bitfield vocabulary for `SceneServer.Movement.Ack.correction_flags`.

  Two-way contract with:
    * `apps/scene_server/native/movement_core/src/ack.rs`
    * `clients/bevy_client/src/sim/correction.rs`

  Bits are OR-combined by the server (physics push + status override can
  coexist) and branched on by the client to pick a reconciliation strategy.
  Keep the bit values here in lock-step with the Rust and client sides.
  """

  import Bitwise

  @none 0x00000000
  @teleport 0x00000001
  @collision_push 0x00000002
  @status_override 0x00000004
  @anti_cheat_reject 0x00000008

  @type t :: non_neg_integer()

  @doc "Empty flag set."
  @spec none() :: t()
  def none, do: @none

  @doc "Scripted teleport / respawn / cross-scene transition."
  @spec teleport() :: t()
  def teleport, do: @teleport

  @doc "Physics pushed the avatar against input direction (wall, knockback)."
  @spec collision_push() :: t()
  def collision_push, do: @collision_push

  @doc "Status effect overrides velocity or movement mode."
  @spec status_override() :: t()
  def status_override, do: @status_override

  @doc "Anti-cheat rejected the client-reported trajectory."
  @spec anti_cheat_reject() :: t()
  def anti_cheat_reject, do: @anti_cheat_reject

  @doc "Combines a list of flag bits via bitwise OR."
  @spec combine([t()]) :: t()
  def combine(flags) when is_list(flags) do
    Enum.reduce(flags, @none, &bor/2)
  end

  @doc "True when `probe` bits are all set in `flags`. Empty probe returns false."
  @spec contains?(t(), t()) :: boolean()
  def contains?(_flags, 0), do: false

  def contains?(flags, probe)
      when is_integer(flags) and is_integer(probe) and flags >= 0 and probe >= 0 do
    band(flags, probe) == probe
  end

  @doc "Shorthand predicates for the individual bits."
  @spec teleport?(t()) :: boolean()
  def teleport?(flags), do: contains?(flags, @teleport)

  @spec collision_push?(t()) :: boolean()
  def collision_push?(flags), do: contains?(flags, @collision_push)

  @spec status_override?(t()) :: boolean()
  def status_override?(flags), do: contains?(flags, @status_override)

  @spec anti_cheat_reject?(t()) :: boolean()
  def anti_cheat_reject?(flags), do: contains?(flags, @anti_cheat_reject)
end
