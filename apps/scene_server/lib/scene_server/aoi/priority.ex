defmodule SceneServer.Aoi.Priority do
  @moduledoc """
  AOI priority policy for movement snapshot fan-out.

  The AOI workers own runtime subscriptions and the octree; this module owns no
  process state. It converts nearby AOI entries into per-observer delivery
  targets and decides whether a movement snapshot should be sent on a given
  authoritative tick.
  """

  alias SceneServer.Movement.RemoteSnapshot

  @type vector :: {float(), float(), float()}
  @type band :: :high | :medium | :low

  @type target :: %{
          required(:cid) => integer(),
          required(:aoi_pid) => pid(),
          required(:location) => vector(),
          required(:distance) => float(),
          required(:priority_band) => band(),
          required(:priority_score) => float(),
          required(:delivery_interval) => pos_integer()
        }

  @doc """
  Builds sorted AOI delivery targets from manager entries.

  Targets are sorted nearest-first. `radius` is the observer radius used for
  priority scoring and band classification.
  """
  @spec build_targets([map()], vector(), pos_integer() | float()) :: [target()]
  def build_targets(entries, origin, radius) when is_list(entries) do
    safe_radius = max(radius * 1.0, 1.0)

    entries
    |> Enum.map(&target_from_entry(&1, origin, safe_radius))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.distance)
  end

  @doc """
  Returns whether the target should receive this movement snapshot.

  High-priority targets receive every snapshot, medium targets every other
  authoritative tick, and low-priority targets every fifth tick. Stop snapshots
  are always delivered so remote clients converge cleanly after throttling.
  """
  @spec due?(RemoteSnapshot.t(), target()) :: boolean()
  def due?(%RemoteSnapshot{} = snapshot, %{delivery_interval: interval})
      when is_integer(interval) and interval > 0 do
    stopped?(snapshot) or rem(snapshot.server_tick, interval) == 0
  end

  @doc """
  Adds observer-specific priority metadata to a remote movement snapshot.
  """
  @spec decorate_snapshot(RemoteSnapshot.t(), target()) :: RemoteSnapshot.t()
  def decorate_snapshot(%RemoteSnapshot{} = snapshot, target) do
    RemoteSnapshot.with_priority(snapshot, %{
      priority_band: target.priority_band,
      priority_score: target.priority_score,
      observer_distance: target.distance,
      delivery_interval: target.delivery_interval
    })
  end

  @doc """
  Returns the send interval for a priority band.
  """
  @spec delivery_interval(band()) :: pos_integer()
  def delivery_interval(:high), do: 1
  def delivery_interval(:medium), do: 2
  def delivery_interval(:low), do: 5

  @doc """
  Classifies an observer distance inside the AOI radius into a priority band.
  """
  @spec classify(float(), pos_integer() | float()) :: band()
  def classify(distance, radius) do
    ratio = distance / max(radius * 1.0, 1.0)

    cond do
      ratio <= 0.35 -> :high
      ratio <= 0.75 -> :medium
      true -> :low
    end
  end

  @doc """
  Computes a normalized interest score where `1.0` is nearest/most important.
  """
  @spec score(float(), pos_integer() | float()) :: float()
  def score(distance, radius) do
    max(0.0, min(1.0, 1.0 - distance / max(radius * 1.0, 1.0)))
  end

  defp target_from_entry(%{aoi_pid: pid, cid: cid, location: location}, origin, radius)
       when is_pid(pid) do
    distance = distance(origin, location)
    band = classify(distance, radius)

    %{
      cid: cid,
      aoi_pid: pid,
      location: location,
      distance: distance,
      priority_band: band,
      priority_score: score(distance, radius),
      delivery_interval: delivery_interval(band)
    }
  end

  defp target_from_entry(_entry, _origin, _radius), do: nil

  defp distance({ax, ay, az}, {bx, by, bz}) do
    :math.sqrt(:math.pow(ax - bx, 2) + :math.pow(ay - by, 2) + :math.pow(az - bz, 2))
  end

  defp stopped?(%RemoteSnapshot{velocity: velocity, acceleration: acceleration}) do
    zero_vector?(velocity) and zero_vector?(acceleration)
  end

  defp zero_vector?({x, y, z}) do
    abs(x) <= 1.0e-9 and abs(y) <= 1.0e-9 and abs(z) <= 1.0e-9
  end
end
