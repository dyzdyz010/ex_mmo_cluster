# Ghost-block root-cause probe: compare chunk -14,8,-4 macro 2923 across
#   (1) LIVE storage (what break-check reads)  vs
#   (2) the SNAPSHOT bytes a subscriber receives (what the client renders).
#
# If they agree for every macro + chunk_version matches → no server-side
# snapshot/live divergence → the ghost is client-side staleness (subscription
# not kept authoritative). If they disagree → the snapshot source is stale and
# we have localized the server-side bug.
#
# Run:  $env:ERL_EPMD_PORT="43690"; elixir --sname probe --cookie mmo scripts/probe_ghost_chunk.exs

node = :"dev@DYZ-BAK"
true = Node.connect(node)

scene_id = 1
coord = {-14, 8, -4}
macro = 2923

dir = SceneServer.Voxel.ChunkDirectory
cp = SceneServer.Voxel.ChunkProcess
storage_mod = SceneServer.Voxel.Storage
codec = SceneServer.Voxel.Codec

mode_name = fn
  0 -> "EMPTY/air"
  1 -> "SOLID"
  2 -> "REFINED"
  other -> "??#{inspect(other)}"
end

# Small helper: count modes in a header list (headers are struct-as-map after RPC).
count_modes = fn headers ->
  Enum.reduce(headers, %{0 => 0, 1 => 0, 2 => 0}, fn h, acc ->
    m = Map.get(h, :mode)
    Map.update(acc, m, 1, &(&1 + 1))
  end)
end

IO.puts("\n===== GHOST PROBE: scene #{scene_id} chunk #{inspect(coord)} macro #{macro} =====")

# (1) Force-start the chunk from durable PG, read LIVE debug_state.
ensure = :rpc.call(node, dir, :ensure_chunk, [%{logical_scene_id: scene_id, chunk_coord: coord}])
IO.inspect(ensure, label: "ensure_chunk")

case ensure do
  {:ok, pid} ->
    dbg = :rpc.call(node, cp, :debug_state, [pid])
    live = Map.get(dbg, :storage)
    live_headers = Map.get(live, :macro_headers)
    live_blocks = Map.get(live, :normal_blocks)
    live_refined = Map.get(live, :refined_cells)

    IO.puts("\n--- LIVE storage ---")
    IO.inspect(Map.get(dbg, :chunk_version), label: "live chunk_version")
    IO.inspect(Map.get(dbg, :subscriber_count), label: "live subscriber_count")
    IO.inspect(Map.get(dbg, :has_lease?), label: "has_lease?")
    IO.inspect(length(live_headers), label: "macro_headers len")
    IO.inspect(length(live_blocks), label: "normal_blocks pool len")
    IO.inspect(length(live_refined), label: "refined_cells pool len")
    IO.inspect(count_modes.(live_headers), label: "live mode histogram {empty,solid,refined}")

    live_h = Enum.at(live_headers, macro)
    lm = Map.get(live_h, :mode)
    IO.puts("\n>>> LIVE macro #{macro}: mode=#{lm} (#{mode_name.(lm)}), payload_index=#{Map.get(live_h, :payload_index)}")
    IO.inspect(:rpc.call(node, storage_mod, :normal_block_at, [live, macro]), label: "LIVE normal_block_at(2923)")
    # THE break-check predicate (what apply_intent validates against):
    for s <- [0, 255, 511] do
      occ = :rpc.call(node, storage_mod, :micro_slot_occupied?, [live, macro, s])
      IO.puts("    LIVE micro_slot_occupied?(2923, #{s}) = #{inspect(occ)}   <-- break-check sees this")
    end

    # (2) Fresh SNAPSHOT bytes (what a (re)subscribing client receives), decoded.
    snap_res =
      :rpc.call(node, dir, :snapshot_payload, [
        %{logical_scene_id: scene_id, chunk_coord: coord, request_id: 0}
      ])

    case snap_res do
      {:ok, payload} ->
        IO.puts("\n--- SNAPSHOT bytes (#{byte_size(payload)} B) decoded ---")
        snap = :rpc.call(node, codec, :decode_chunk_snapshot_payload!, [payload])
        snap_storage = Map.get(snap, :storage)
        snap_headers = Map.get(snap_storage, :macro_headers)
        snap_blocks = Map.get(snap_storage, :normal_blocks)

        IO.inspect(Map.get(snap_storage, :chunk_version), label: "snapshot chunk_version")
        IO.inspect(Map.get(snap, :chunk_hash), label: "snapshot chunk_hash (encoded)")
        IO.inspect(length(snap_blocks), label: "snapshot normal_blocks pool len")
        IO.inspect(count_modes.(snap_headers), label: "snapshot mode histogram {empty,solid,refined}")

        snap_h = Enum.at(snap_headers, macro)
        sm = Map.get(snap_h, :mode)
        IO.puts("\n>>> SNAPSHOT macro #{macro}: mode=#{sm} (#{mode_name.(sm)}), payload_index=#{Map.get(snap_h, :payload_index)}")

        # (3) THE VERDICT: do live and snapshot agree, macro-by-macro?
        mismatches =
          Enum.zip(live_headers, snap_headers)
          |> Enum.with_index()
          |> Enum.filter(fn {{lh, sh}, _i} -> Map.get(lh, :mode) != Map.get(sh, :mode) end)

        IO.puts("\n===== VERDICT =====")
        IO.puts("macro 2923: LIVE=#{mode_name.(lm)}  vs  SNAPSHOT=#{mode_name.(sm)}  → #{if lm == sm, do: "AGREE", else: "DIVERGE"}")
        IO.puts("full-chunk header-mode mismatches (live vs snapshot): #{length(mismatches)} / 4096")

        mismatches
        |> Enum.take(20)
        |> Enum.each(fn {{lh, sh}, i} ->
          IO.puts("    macro #{i}: live=#{mode_name.(Map.get(lh, :mode))} snapshot=#{mode_name.(Map.get(sh, :mode))}")
        end)

        if Map.get(live, :chunk_version) != Map.get(snap_storage, :chunk_version) do
          IO.puts("\n⚠ chunk_version DIFFERS: live=#{Map.get(live, :chunk_version)} snapshot=#{Map.get(snap_storage, :chunk_version)} → snapshot source is STALE vs live")
        else
          IO.puts("\nchunk_version matches (live == snapshot == #{Map.get(live, :chunk_version)})")
        end

      other ->
        IO.inspect(other, label: "snapshot_payload ERROR")
    end

  other ->
    IO.inspect(other, label: "ensure_chunk failed")
end

IO.puts("\n===== END =====")
