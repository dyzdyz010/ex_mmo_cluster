defmodule MmoContracts.EnvelopeTest do
  use ExUnit.Case, async: true

  alias MmoContracts.Envelope

  alias MmoContracts.Envelope.{
    AuthCommand,
    SystemCommand,
    AuthEvent,
    CellTime,
    ReplicationOut,
    PersistenceMeta
  }

  describe "Envelope.cast/3 必填语义" do
    defmodule Sample do
      defstruct [:a, :b, :c]
    end

    test "原子=必填,缺失即报告" do
      assert {:error, {:missing_required, [:a]}} = Envelope.cast(Sample, %{b: 1}, [:a])
      assert {:ok, %Sample{a: 1}} = Envelope.cast(Sample, %{a: 1}, [:a])
    end

    test "列表=至少其一" do
      assert {:error, {:missing_required, [[:b, :c]]}} =
               Envelope.cast(Sample, %{a: 1}, [[:b, :c]])

      assert {:ok, _} = Envelope.cast(Sample, %{a: 1, b: 2}, [[:b, :c]])
      assert {:ok, _} = Envelope.cast(Sample, %{a: 1, c: 3}, [[:b, :c]])
    end

    test "未知键被忽略" do
      assert {:ok, %Sample{a: 1}} = Envelope.cast(Sample, %{a: 1, zzz: 9}, [:a])
    end
  end

  describe "AuthCommand(AUTH-1)" do
    @valid %{
      command_id: "c1",
      actor_id: "a1",
      cell_id: "cell1",
      owner_epoch: 1,
      client_seq: 7,
      target_tick: 100,
      payload_type: :place_block,
      payload_version: 1,
      payload: %{}
    }

    test "合法命令构造成功" do
      assert {:ok, %AuthCommand{command_id: "c1"}} = AuthCommand.new(@valid)
    end

    test "target_tick 或 server_received_tick 至少其一(A 或 B)" do
      no_tick = Map.drop(@valid, [:target_tick])

      assert {:error, {:missing_required, [[:target_tick, :server_received_tick]]}} =
               AuthCommand.new(no_tick)

      assert {:ok, _} =
               no_tick |> Map.put(:server_received_tick, 200) |> AuthCommand.new()
    end

    test "缺 command_id 报错" do
      assert {:error, {:missing_required, specs}} =
               AuthCommand.new(Map.drop(@valid, [:command_id]))

      assert :command_id in specs
    end

    test "new!/1 缺字段 raise" do
      assert_raise ArgumentError, ~r/缺少必填字段/, fn -> AuthCommand.new!(%{}) end
    end
  end

  describe "SystemCommand(AUTH-11)" do
    test "系统命令需 system_actor/rule_version/idempotency_key/causation_id" do
      base = %{
        command_id: "sc1",
        cell_id: "cell1",
        owner_epoch: 2,
        target_tick: 10,
        payload_type: :burn_block,
        payload_version: 1
      }

      assert {:error, {:missing_required, specs}} = SystemCommand.new(base)
      assert :system_actor in specs

      ok =
        base
        |> Map.merge(%{
          system_actor: :fire_system,
          rule_version: "fire@1",
          idempotency_key: "idem-1",
          causation_id: "cause-1"
        })

      assert {:ok, %SystemCommand{system_actor: :fire_system}} = SystemCommand.new(ok)
    end
  end

  describe "AuthEvent(EVENT-2)" do
    test "最小字段校验" do
      assert {:error, {:missing_required, _}} = AuthEvent.new(%{event_id: "e1"})

      assert {:ok, %AuthEvent{}} =
               AuthEvent.new(%{
                 event_id: "e1",
                 event_type: :block_placed,
                 schema_version: 1,
                 cell_id: "cell1",
                 owner_epoch: 1,
                 cell_seq: 42,
                 tick_id: 100,
                 delivery_class: :reliable_ordered
               })
    end
  end

  describe "CellTime(TIME-1)" do
    test "cell_tick + sim_time 必填" do
      assert {:error, _} = CellTime.new(%{cell_tick: 1})

      assert {:ok, %CellTime{cell_tick: 1, sim_time: 2.5}} =
               CellTime.new(%{cell_tick: 1, sim_time: 2.5})
    end
  end

  describe "ReplicationOut(REPL / AUTH-8)" do
    @base %{observer_id: "o1", cell_id: "cell1", snapshot_seq: 5}

    test "合法 reliability_class 通过" do
      assert {:ok, %ReplicationOut{}} =
               ReplicationOut.new(Map.put(@base, :reliability_class, :unreliable_snapshot))
    end

    test "非法 reliability_class 报错" do
      assert {:error, {:invalid_reliability_class, :bogus}} =
               ReplicationOut.new(Map.put(@base, :reliability_class, :bogus))
    end

    test "四个可靠性类别" do
      assert ReplicationOut.reliability_classes() == [
               :reliable_ordered,
               :reliable_unordered,
               :unreliable_snapshot,
               :bulk_stream
             ]
    end
  end

  describe "PersistenceMeta(PERS-5 / PERS-7)" do
    test "state_class 必须是四分类之一" do
      assert {:error, {:invalid_state_class, :nope}} =
               PersistenceMeta.new(%{state_class: :nope, schema_version: 1})

      assert {:ok, %PersistenceMeta{state_class: :durable_authoritative}} =
               PersistenceMeta.new(%{state_class: :durable_authoritative, schema_version: 1})
    end

    test "derived 必须带 rebuild_algorithm_version(PERS-7)" do
      assert {:error, :derived_requires_rebuild_algorithm_version} =
               PersistenceMeta.new(%{state_class: :derived, schema_version: 1})

      assert {:ok, %PersistenceMeta{}} =
               PersistenceMeta.new(%{
                 state_class: :derived,
                 schema_version: 1,
                 rebuild_algorithm_version: "diffusion@1"
               })
    end
  end
end
