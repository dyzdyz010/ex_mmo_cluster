defmodule SceneServer.Movement.ToolHit do
  @moduledoc "Global system：当前姿态的工具射线与 Y-up 移动胶囊求交；不持有身体或命中结果。"

  @doc "球沿有限线段扫掠当前胶囊，返回 0..1 首次接触参数；起始重叠返回 0。"
  def sweep({ax, ay, az} = a, {bx, by, bz}, radius, {cx, cy, cz} = center, profile) do
    r = profile.radius + radius
    h = profile.half_height - profile.radius
    dy = max(abs(ay - cy) - h, 0.0)
    length = :math.sqrt((bx - ax) ** 2 + (by - ay) ** 2 + (bz - az) ** 2)

    cond do
      (ax - cx) ** 2 + dy ** 2 + (az - cz) ** 2 <= r * r -> {:ok, 0.0}
      length == 0.0 -> :miss
      true ->
        p = %{profile | radius: r, half_height: profile.half_height + radius}
        case ray(a, {(bx - ax) / length, (by - ay) / length, (bz - az) / length}, center, p, length) do
          {:ok, distance, _part} -> {:ok, distance / length}
          :miss -> :miss
        end
    end
  end

  @doc "返回射程内最近交点和粗部位；胶囊尺寸直接来自已发布移动 profile。"
  def ray({ox, oy, oz}, {dx, dy, dz}, {cx, cy, cz}, profile, range) do
    {x, y, z} = {ox - cx, oy - cy, oz - cz}
    r = profile.radius
    h = profile.half_height - r

    cylinder =
      for t <- roots(dx * dx + dz * dz, x * dx + z * dz, x * x + z * z - r * r),
          abs(y + t * dy) <= h,
          do: t

    caps =
      for cap <- [-h, h],
          t <-
            roots(
              1.0,
              x * dx + (y - cap) * dy + z * dz,
              x * x + (y - cap) * (y - cap) + z * z - r * r
            ),
          (cap < 0 and y + t * dy <= -h) or (cap >= 0 and y + t * dy >= h),
          do: t

    case Enum.filter(cylinder ++ caps, &(&1 >= 0 and &1 <= range)) do
      [] ->
        :miss

      hits ->
        t = Enum.min(hits)
        height = (y + t * dy + profile.half_height) / (2 * profile.half_height)

        part =
          cond do
            height >= 0.8 -> :head
            height < 0.45 -> :legs
            true -> :torso
          end

        {:ok, t, part}
    end
  end

  defp roots(a, b, c) do
    discriminant = b * b - a * c

    if a == 0.0 or discriminant < 0.0,
      do: [],
      else: [(-b - :math.sqrt(discriminant)) / a, (-b + :math.sqrt(discriminant)) / a]
  end

  @doc "双方中心均在显式战斗范围内才允许；未配置范围的正式世界拒绝。"
  def permitted?(nil, _, _), do: false

  def permitted?({low, high}, a, b),
    do:
      Enum.all?([a, b], fn p ->
        Enum.all?(0..2, &(elem(p, &1) >= elem(low, &1) and elem(p, &1) < elem(high, &1)))
      end)
end
