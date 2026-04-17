defmodule SceneServer.Native.CoordinateSystem do
  @moduledoc """
  Legacy/native coordinate-system binding kept for lower-level scene helpers.

  The AOI runtime now primarily uses the octree binding, but these adapters are
  still part of the native scene toolkit and remain useful for tests and older
  scene operations.
  """

  use Rustler, otp_app: :scene_server, crate: "coordinate_system"

  alias SceneServer.Native.CoordinateSystem.Types

  @doc "Creates one coordinate-system item."
  @spec new_item(integer(), {number(), number(), number()}) :: {atom(), Types.sorted_set()}
  def new_item(_cid, _coord), do: error()

  @doc "Updates the coordinate of one coordinate-system item."
  @spec update_item_coord(Types.item(), {number(), number(), number()}) ::
          {:ok, atom()} | {:error, atom()}
  def update_item_coord(_item, _coord), do: error()

  @doc "Reads the raw representation of one coordinate-system item."
  @spec get_item_raw(Types.item()) :: {atom(), Types.item()} | {atom(), any()}
  def get_item_raw(_item), do: error()

  @doc "Creates a bucket used by the coordinate-system binding."
  @spec new_bucket() :: {atom(), Types.bucket()}
  def new_bucket(), do: error()

  @doc "Adds an item to a bucket."
  @spec add_item_to_bucket(Types.bucket(), integer(), {number(), number(), number()}) ::
          {atom(), any()}
  def add_item_to_bucket(_bucket, _cid, _coord), do: error()

  @doc "Reads the raw representation of a bucket."
  @spec get_bucket_raw(Types.bucket()) :: {atom(), Types.bucket()} | {atom(), any()}
  def get_bucket_raw(_bucket), do: error()

  @doc "Creates a sorted-set container."
  @spec new_set(integer(), integer()) :: {atom(), Types.sorted_set()}
  def new_set(_set_capacity, _bucket_capacity), do: error()

  @doc "Adds an item to a sorted-set container."
  @spec add_item_to_set(Types.sorted_set(), integer(), {number(), number(), number()}) ::
          {atom(), any()}
  def add_item_to_set(_sorted_set, _cid, _coord), do: error()

  @doc "Reads the raw representation of a sorted set."
  @spec get_set_raw(Types.sorted_set()) :: {atom(), Types.sorted_set()} | {atom(), any()}
  def get_set_raw(_sorted_set), do: error()

  @doc "Creates a complete coordinate system."
  @spec new_system(integer(), integer()) :: {atom(), Types.coordinate_system()}
  def new_system(_set_capacity, _bucket_capacity), do: error()

  @doc "Adds an item to the coordinate system."
  @spec add_item_to_system(Types.coordinate_system(), integer(), {number(), number(), number()}) ::
          {:ok, Types.item()} | {:err, atom()}
  def add_item_to_system(_system, _cid, _coord), do: error()

  @doc "Removes an item from the coordinate system."
  @spec remove_item_from_system(Types.coordinate_system(), Types.item()) ::
          {:ok, {integer(), integer(), integer()}} | {:err, atom()}
  def remove_item_from_system(_system, _item), do: error()

  @doc "Updates an item's position in the coordinate system."
  @spec update_item_from_system(Types.coordinate_system(), Types.item(), tuple()) ::
          {:ok, {integer(), integer(), integer()}} | {:err, atom()}
  def update_item_from_system(_system, _item, _new_position), do: error()

  @doc "Alternative coordinate-system update entrypoint kept for legacy callers."
  @spec update_item_from_system_new(Types.coordinate_system(), Types.item(), tuple()) ::
          {{integer(), integer(), integer()}, atom()}
  def update_item_from_system_new(_system, _item, _new_position), do: error()

  @doc "Finds nearby CIDs around one item."
  @spec get_cids_within_distance_from_system(Types.coordinate_system(), Types.item(), number()) ::
          {:ok, [integer()]} | {:err, any()}
  def get_cids_within_distance_from_system(_system, _item, _distance), do: error()

  @doc "Finds nearby raw items around one item."
  @spec get_items_within_distance_from_system(Types.coordinate_system(), Types.item(), number()) ::
          {:ok, [map()]} | {:err, any()}
  def get_items_within_distance_from_system(_system, _item, _distance), do: error()

  @doc "Returns a raw representation of the coordinate system."
  @spec get_system_raw(Types.coordinate_system()) ::
          {atom(), Types.sorted_set()} | {atom(), any()}
  def get_system_raw(_system), do: error()

  @doc "Projects a coordinate forward from velocity across a time interval."
  @spec calculate_coordinate(integer(), integer(), Types.vector(), Types.vector()) ::
          Types.vector()
  def calculate_coordinate(_old_timestamp, _new_timestamp, _location, _velocity), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
