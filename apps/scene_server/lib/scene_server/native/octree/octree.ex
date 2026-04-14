defmodule SceneServer.Native.Octree do
  @moduledoc """
  Rustler binding for the octree used by the AOI manager.

  `SceneServer.AoiManager` uses this module as its spatial index backend.
  """

  use Rustler, otp_app: :scene_server, crate: "octree"

  alias SceneServer.Native.Octree.Types

  @doc "Creates a new octree rooted at the given center/half-size."
  @spec new_tree(Types.vector(), Types.vector()) :: Types.octree()
  def new_tree(_center, _half_size), do: error()

  @doc "Creates a new octree item representing one actor at a position."
  @spec new_item(integer(), Types.vector()) :: Types.octree_item()
  def new_item(_cid, _pos), do: error()

  @doc "Adds an item to an octree."
  @spec add_item(Types.octree(), Types.octree_item()) :: Types.octree()
  def add_item(_tree, _item), do: error()

  @doc "Removes an item from an octree."
  @spec remove_item(Types.octree(), Types.octree_item()) :: boolean()
  def remove_item(_tree, _item), do: error()

  @doc "Returns CIDs inside a box centered at the given point."
  @spec get_in_bound(Types.octree(), Types.vector(), Types.vector()) :: [integer()]
  def get_in_bound(_tree, _center, _half_size), do: error()

  @doc "Returns CIDs inside a box, excluding the provided octree item."
  @spec get_in_bound_except(Types.octree(), Types.octree_item(), Types.vector()) :: [integer()]
  def get_in_bound_except(_tree, _item, _half_size), do: error()

  @doc "Returns a raw representation for debugging/tests."
  @spec get_tree_raw(Types.octree()) :: map()
  def get_tree_raw(_tree), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
