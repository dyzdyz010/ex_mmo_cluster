defmodule SceneServer.Native.SceneOps do
  use Rustler, otp_app: :scene_server, crate: "scene_ops"

  @type vector :: {float(), float(), float()}

  @spec new_character_data(integer(), binary(), vector(), map()) :: {atom(), reference()}
  def new_character_data(_cid, _nickname, _location, _dev_attrs), do: error()

  @spec update_character_movement(reference(), vector(), vector(), vector()) :: {atom(), atom()}
  def update_character_movement(_cdref,_location, _velocity, _acceleration), do: error()

  @spec get_character_location(reference()) :: {:ok, term()} | {:err, atom()}
  def get_character_location(_cdref), do: error()


  @spec get_character_data_raw(reference()) :: {:ok, term()} | {:err, atom()}
  def get_character_data_raw(_cdref), do: error()

  @spec movement_tick(reference()) :: any()
  def movement_tick(_cdref), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
