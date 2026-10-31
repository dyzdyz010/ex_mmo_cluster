defmodule VoxelRegion.AccessTest do
  @moduledoc """
  只测试：统一授权表 `VoxelRegion.Access` 的结构性保证（纯函数与源码扫描，不启动 World）。

  - 登记完整：World 的每种消息都有动作类，与 `World.Closure.registered_entries/0` 一一对应；新加消息漏登记即红。
  - 策略矩阵：各主体对各动作类的允许 / 拒绝。
  - 准入：未登记消息拒绝；准备包装不能绕过原始编辑的授权。
  - 调用方白名单：服务玩家与 NPC 的 app（gate / scene / npc）不得调用运维专用的 World 写 API，
    原始编辑必须显式带角色或创世主体。
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias VoxelRegion.Access
  alias VoxelRegion.World.Closure

  test "World 每种消息都登记了动作类，且没有多余登记" do
    closure =
      Closure.registered_entries() |> Map.values() |> List.flatten() |> MapSet.new(&elem(&1, 0))

    access = Access.messages() |> Map.keys() |> Enum.concat(Access.wrappers()) |> MapSet.new()
    # 左侧非空：这些 World 消息还没有动作类，去 `Access` 的 @messages 里登记
    assert closure |> MapSet.difference(access) |> Enum.sort() == []
    # 左侧非空：授权表里有 World 已不存在的消息，删掉
    assert access |> MapSet.difference(closure) |> Enum.sort() == []
  end

  test "每个动作类都有策略" do
    for action <- Access.messages() |> Map.values() |> Enum.uniq(),
        do: assert(Map.has_key?(Access.policy(), action), "动作类 #{action} 没有策略")
  end

  test "策略矩阵" do
    capture_log(fn ->
      assert :ok = Access.authorize({:character, 1}, :character_intent)
      assert {:error, :forbidden} = Access.authorize({:character, 1}, :raw_edit)
      assert :ok = Access.authorize({:genesis, 1}, :raw_edit)
      assert :ok = Access.authorize(:operator, :raw_edit)
      assert {:error, :forbidden} = Access.authorize({:character, 1}, :gm_build)
      assert {:error, :forbidden} = Access.authorize({:genesis, 1}, :world_authoring)
      assert :ok = Access.authorize(:operator, :gm_build)
      assert :ok = Access.authorize({:character, 1}, :read)
    end)
  end

  test "准入：未登记消息拒绝，准备包装按原消息判定" do
    log =
      capture_log(fn ->
        assert {:error, :unregistered_message} = Access.admit({:brand_new_write, :x})
        raw = {:apply_edits, {:character, 7}, [{{0, 0, 0}, 0}]}
        assert {:error, :forbidden} = Access.admit(raw)
        assert {:error, :forbidden} = Access.admit({:prepare_intent, raw})
        assert {:error, :forbidden} = Access.admit({:prepared_intent, [], raw, []})
        assert :ok = Access.admit({:apply_edits, {:genesis, 7}, [{{0, 0, 0}, 0}]})
        assert :ok = Access.admit(:seq)
      end)

    assert log =~
             "world_access_denied principal={:character, 7} action=:raw_edit reason=forbidden"
  end

  test "保护区：角色与创世只能改野外和自己的区域，运维不受约束" do
    p =
      VoxelRegion.Protection.apply(
        VoxelRegion.Protection.new(),
        %{
          {1, 1} => %{
            holder: :reserved,
            min: {0, 0},
            max: {9, 9},
            created_seq: 1,
            created_by: nil
          }
        }
      )

    capture_log(fn ->
      assert {:error, :protected_region} =
               Access.authorize_cells({:genesis, 1}, p, [{5, 0, 5}], :raw_edit)

      assert {:error, :protected_region} =
               Access.authorize_cells({:character, 1}, p, [{5, 0, 5}], :raw_edit)

      assert :ok = Access.authorize_cells({:genesis, 1}, p, [{20, 0, 20}], :raw_edit)
      assert :ok = Access.authorize_cells(:operator, p, [{5, 0, 5}], :raw_edit)
    end)
  end

  test "提交写集：运维与系统不算写集；角色写进别人的区域整笔拒绝；没有保护区时直接通过" do
    p = reserved_square()
    never = fn -> flunk("运维、系统或无保护区时不应计算写集") end

    assert :ok = Access.authorize_writes(:operator, p, never)
    assert :ok = Access.authorize_writes(:system, p, never)
    assert :ok = Access.authorize_writes({:character, 1}, VoxelRegion.Protection.new(), never)
    assert :ok = Access.authorize_writes({:character, 1}, p, fn -> [{20, 0, 20}] end)

    capture_log(fn ->
      assert {:error, :protected_region} =
               Access.authorize_writes({:character, 1}, p, fn -> MapSet.new([{20, 0, 20}, {5, 0, 5}]) end)
    end)

    refute Access.writable?({:genesis, 1}, p, [{5, 0, 5}])
    assert Access.writable?(:operator, p, [{5, 0, 5}])
  end

  # 两个执行点之外不再判保护区：规则只在 Access，提交只经 World.Log 一个入口。
  test "保护区判定只在 Access，日志追加只在 World.Log" do
    lib = Path.join(__DIR__, "../lib")
    files = Path.wildcard(Path.join(lib, "**/*.ex"))
    relative = &Path.relative_to(&1, lib)

    permitted = for f <- files, File.read!(f) =~ "Protection.permitted?", do: relative.(f)
    assert permitted == ["voxel_region/access.ex"]

    appends = for f <- files, File.read!(f) =~ ~r/backend\.append\(/, do: relative.(f)
    assert appends == ["voxel_region/world/log.ex"]
  end

  defp reserved_square do
    VoxelRegion.Protection.apply(VoxelRegion.Protection.new(), %{
      {1, 1} => %{holder: :reserved, min: {0, 0}, max: {9, 9}, created_seq: 1, created_by: nil}
    })
  end

  test "gate / scene / npc 不调用运维专用的 World 写 API，原始编辑显式带主体" do
    operator_only =
      for {tag, action} <- Access.messages(),
          action in [:gm_build, :world_authoring],
          do: Atom.to_string(tag)

    apps = Path.join(__DIR__, "../..")

    violations =
      for app <- ~w(gate_server scene_server npc_server),
          file <- Path.wildcard(Path.join([apps, app, "lib/**/*.ex"])),
          violation <- violations(File.read!(file), operator_only),
          do: "#{Path.relative_to(file, apps)}: #{violation}"

    assert violations == []
  end

  # 按整份源码匹配（调用可能被格式化成多行）：原始编辑的第二个参数必须是角色或创世主体字面量。
  defp violations(source, operator_only) do
    raw_calls = Regex.scan(~r/World\.apply_edits?\(\s*[^,]+,\s*(\S+)/, source)

    raw =
      for [call, second] <- raw_calls,
          not String.starts_with?(second, ["{:character,", "{:genesis,"]),
          do: "原始编辑未显式带角色或创世主体：#{call}"

    operator =
      for name <- operator_only,
          Regex.match?(~r/World\.#{name}\(/, source),
          do: "调用了运维专用的 World.#{name}"

    raw ++ operator
  end
end
