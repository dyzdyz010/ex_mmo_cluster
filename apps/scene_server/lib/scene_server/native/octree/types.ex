defmodule SceneServer.Native.Octree.Types do
  @moduledoc """
  Reference type aliases for the octree Rustler bindings.
  """

  @type octree :: reference()

  @type octree_item :: reference()

  @type vector :: {float(), float(), float()}
end
