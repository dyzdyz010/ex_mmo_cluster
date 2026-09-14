defmodule VoxelRegion.Damage do
  @moduledoc "B1 immutable property lookup and exact canonical micro-grid ray traversal."

  @micro VoxelRegion.Spatial.micro_resolution()

  def load(path) do
    bytes = File.read!(path)
    data = Jason.decode!(bytes)
    1 = data["schema_version"]
    materials = Map.new(data["materials"], &{&1["material_id"], &1})
    tools = Map.new(data["tools"], &{&1["tool_id"], &1})
    tags = MapSet.new(data["tags"],& &1["id"])
    true = MapSet.member?(tags,"damage")
    true = map_size(materials)==length(data["materials"]) and map_size(tools)==length(data["tools"])
    true = Enum.all?(0..23, &Map.has_key?(materials,&1))
    true = Enum.all?(materials, fn {id,m} ->
      is_number(m["max_hp_per_macro"]) and (id == 0 or m["max_hp_per_macro"] > 0) and
        is_number(m["defense"]) and m["defense"] >= 0 and
        Enum.all?(m["tags"],&MapSet.member?(tags,&1)) and
        Enum.any?(m["responses"],&(&1["action"]=="damage")) and
        length(Enum.uniq_by(m["responses"],& &1["action"]))==length(m["responses"]) and
        Enum.all?(m["responses"],fn r -> MapSet.member?(tags,r["action"]) and
          is_number(r["multiplier"]) and r["multiplier"]>=0 end)
    end)
    true = Enum.all?(tools, fn {id,t} -> id in 1..65535 and t["power"] > 0 and
      t["range_macro"] > 0 and t["interval_seconds"] > 0 and MapSet.member?(tags,t["action"]) and
      (t["action"]=="damage" or String.starts_with?(t["action"],"damage.")) end)
    %{digest: :crypto.hash(:sha256,bytes), materials: materials, tools: tools}
  end

  def volume(0), do: 1.0
  def volume(1), do: 1.0/(@micro*@micro*@micro)
  def volume(2), do: 1.0
  def max_hp(material,granularity), do: material["max_hp_per_macro"] * volume(granularity)
  def amount(material,tool,granularity) do
    response = material["responses"]
      |> Enum.filter(fn r -> tool["action"] == r["action"] or String.starts_with?(tool["action"],r["action"]<>".") end)
      |> Enum.max_by(&String.length(&1["action"]))
    max(0.0,tool["power"]-material["defense"]) * response["multiplier"] * volume(granularity)
  end

  @doc "GCRA：一个权威 tick 的相位借用，成功后按理论到达时间偿还；不累积空闲额度。"
  def admit_attack(previous,seq,now,interval,tolerance) do
    cond do
      previous != nil and seq <= previous.seq -> {:error,:replayed_attack}
      previous != nil and now < previous.next_us-tolerance -> {:error,:tool_cooldown}
      true ->
        next = if previous,do: max(now,previous.next_us),else: now
        {:ok,%{seq: seq,next_us: next+interval}}
    end
  end

  def key(%{granularity: 2,owner: owner}), do: {2,owner}
  def key(t), do: {t.granularity,t.micro,t.incarnation,t.owner,t.material}
  def macro(t), do: t.micro |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1,@micro)) |> List.to_tuple()

  # Amanatides-Woo traversal at canonical 1/8 m, including the starting cell.
  def raycast(origin,direction,range,state,at) do
    cell = origin |> Tuple.to_list() |> Enum.map(&floor(&1*@micro)) |> List.to_tuple()
    axes = for i <- 0..2 do
      d = elem(direction,i)
      step = if d < 0,do: -1,else: 1
      if d == 0.0 do
        {step,1.0e100,1.0e100}
      else
        boundary = (elem(cell,i)+if(step > 0,do: 1,else: 0))/@micro
        {step,(boundary-elem(origin,i))/d,abs(1.0/@micro/d)}
      end
    end
    walk(cell,axes,range,state,at)
  end

  defp walk(cell,axes,range,state,at) do
    case at.(cell,state) do
      {nil,state} ->
        {_,distance,_} = Enum.min_by(axes,&elem(&1,1))
        if distance > range do
          {:error,:no_target,state}
        else
          # Simultaneous boundary crossings do not fabricate an edge-only hit.
          {cell,axes} = axes |> Enum.with_index() |> Enum.map_reduce(cell,fn {{step,t,delta},i},cell ->
            if abs(t-distance)<1.0e-10,do: {{step,t+delta,delta},put_elem(cell,i,elem(cell,i)+step)},
              else: {{step,t,delta},cell}
          end) |> then(fn {axes,cell}->{cell,axes} end)
          walk(cell,axes,range,state,at)
        end
      {target,state} -> {:ok,target,state}
    end
  end
end
