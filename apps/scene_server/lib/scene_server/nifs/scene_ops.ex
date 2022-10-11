defmodule SceneServer.Nif.SceneOps do
  use Rustler, otp_app: :scene_server, crate: "sceneserver_nif_sceneops"

  # When your NIF is loaded, it will override this function.
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def subtract(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def multiply(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
