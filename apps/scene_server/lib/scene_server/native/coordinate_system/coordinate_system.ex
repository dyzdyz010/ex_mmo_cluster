defmodule SceneServer.Native.CoordinateSystem do
  use Rustler, otp_app: :scene_server, crate: "coordinate_system"

  alias SceneServer.Native.CoordinateSystem.Types

  @spec new_item(integer(), {number(), number(), number()}) :: {atom(), Types.sorted_set()}
  def new_item(_cid, _coord), do: error()

  @spec get_item_raw(Types.item()) :: {atom(), Types.item()} | {atom(), any()}
  def get_item_raw(_item), do: error()

  @spec new_bucket() :: {atom(), Types.bucket()}
  def new_bucket(), do: error()

  @spec add_item_to_bucket(Types.bucket(), integer(), {number(), number(), number()}) :: {atom(), any()}
  def add_item_to_bucket(_bucket, _cid, _coord), do: error()

  @spec get_bucket_raw(Types.bucket()) :: {atom(), Types.bucket()} | {atom(), any()}
  def get_bucket_raw(_bucket), do: error()

  @spec new_set(integer(), integer()) :: {atom(), Types.sorted_set()}
  def new_set(_set_capacity, _bucket_capacity), do: error()

  @spec add_item_to_set(Types.sorted_set(), integer(), {number(), number(), number()}) :: {atom(), any()}
  def add_item_to_set(_sorted_set, _cid, _coord), do: error()

  @spec get_set_raw(Types.sorted_set()) :: {atom(), Types.sorted_set()} | {atom(), any()}
  def get_set_raw(_sorted_set), do: error()

  @spec new_system(integer(), integer()) :: {atom(), Types.coordinate_system()}
  def new_system(_set_capacity, _bucket_capacity), do: error()

  @spec add_item_to_system(Types.coordinate_system(), integer(), {number(), number(), number()}) :: {:ok, Types.item()} | {:err, atom()}
  def add_item_to_system(_system, _cid, _coord), do: error()

  @spec remove_item_from_system(Types.coordinate_system(), Types.item()) :: {:ok, {integer(), integer(), integer()}} | {:err, atom()}
  def remove_item_from_system(_system, _item), do: error()

  @spec update_item_from_system(Types.coordinate_system(), Types.item(), tuple()) :: {{integer(), integer(), integer()}, atom()}
  def update_item_from_system(_system, _item, _new_position), do: error()

  @spec update_item_from_system_new(Types.coordinate_system(), Types.item(), tuple()) :: {{integer(), integer(), integer()}, atom()}
  def update_item_from_system_new(_system, _item, _new_position), do: error()

  @spec get_items_within_distance_from_system(Types.coordinate_system(), Types.item(), number()) :: {:ok, [integer()]} | {:err, any()}
  def get_items_within_distance_from_system(_system, _item, _distance), do: error()

  @spec get_system_raw(Types.coordinate_system()) :: {atom(), Types.sorted_set()} | {atom(), any()}
  def get_system_raw(_system), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
