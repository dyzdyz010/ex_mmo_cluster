defmodule SceneServer.Native.SortedSet do
  use Rustler, otp_app: :scene_server, crate: "sorted_set"

  alias SceneServer.Native.SortedSet.Types

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

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
