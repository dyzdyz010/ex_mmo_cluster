defmodule SceneServer.Native.SceneOps do
  @moduledoc """
  Rustler binding for scene/physics operations on authoritative characters.

  Actor modules use this layer to create character data, read positions, and
  push authoritative movement into the native scene representation.
  """

  use Rustler, otp_app: :scene_server, crate: "scene_ops"

  @type vector :: {float(), float(), float()}

  @doc "Creates a native scene character representation and returns its reference."
  @spec new_character_data(integer(), binary(), vector(), map(), reference()) ::
          {atom(), reference()}
  def new_character_data(_cid, _nickname, _location, _dev_attrs, _physys_ref), do: error()

  @doc "Creates the shared native physics system."
  @spec new_physics_system() :: {:ok, reference()} | {:err, atom()}
  def new_physics_system(), do: error()

  @doc "Pushes authoritative movement state into native scene data."
  @spec update_character_movement(reference(), vector(), vector(), vector(), reference()) ::
          {atom(), atom()}
  def update_character_movement(_cdref, _location, _velocity, _acceleration, _physys_ref),
    do: error()

  @doc "Reads the current native location for a character reference."
  @spec get_character_location(reference(), reference()) :: {:ok, term()} | {:err, atom()}
  def get_character_location(_cdref, _physys_ref), do: error()

  @doc "Reads the raw native character data for diagnostics/tests."
  @spec get_character_data_raw(reference(), reference()) :: {:ok, term()} | {:err, atom()}
  def get_character_data_raw(_cdref, _physys_ref), do: error()

  @doc "Runs one native scene-side movement tick for a character reference."
  @spec movement_tick(reference(), reference()) :: any()
  def movement_tick(_cdref, _physys_ref), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
