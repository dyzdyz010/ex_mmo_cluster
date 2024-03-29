defmodule SceneServer.Native.Octree do
  use Rustler, otp_app: :scene_server, crate: "octree"

  alias SceneServer.Native.Octree.Types

  @spec new_tree(Types.vector(), Types.vector()) :: Types.octree()
  def new_tree(_center, _half_size), do: error()

  @spec new_item(integer(), Types.vector()) :: Types.octree_item()
  def new_item(_cid, _pos), do: error()

  @spec add_item(Types.octree(), Types.octree_item()) :: Types.octree()
  def add_item(_tree, _item), do: error()

  @spec remove_item(Types.octree(), Types.octree_item()) :: boolean()
  def remove_item(_tree, _item), do: error()

  @spec get_in_bound(Types.octree(), Types.vector(), Types.vector()) :: [integer()]
  def get_in_bound(_tree, _center, _half_size), do: error()

  @spec get_in_bound_except(Types.octree(), Types.octree_item(), Types.vector()) :: [integer()]
  def get_in_bound_except(_tree, _item, _half_size), do: error()

  @spec get_tree_raw(Types.octree()) :: map()
  def get_tree_raw(_tree), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
