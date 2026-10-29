# 只读小型身份摘要；不读取或返回World内部状态。
identity = VoxelRegion.Bench.M0CodeReady.startup_identity!()
native = :code.priv_dir(:voxel_region) |> to_string() |> Path.join("native/*.dll") |> Path.wildcard()
nifs = Map.new(native, fn path -> {Path.expand(path), Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)} end)
Jason.encode!(Map.merge(identity, %{nif_load_directory_files_sha256: nifs,
  kernel_identity: VoxelRegion.Native.kernel_identity(),
  content_version: VoxelRegion.GeneratedStore.hex(VoxelRegion.World.content_version()),
  runtime_otp: to_string(:erlang.system_info(:otp_release)),
  schedulers: :erlang.system_info(:schedulers_online),
  world_stats: Map.take(VoxelRegion.World.stats(), [:published_seq, :dirty_units, :suffix_txns, :resident_pages])}))
