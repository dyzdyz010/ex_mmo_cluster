defmodule SceneServer.Native.CoordinateSystem.Types do
  @moduledoc """
  Reference type aliases for the coordinate-system Rustler bindings.
  """

  @type sorted_set :: reference()

  @type item :: reference()

  @type bucket :: reference()

  @type coordinate_system :: reference()

  @type vector :: {float(), float(), float()}
end
