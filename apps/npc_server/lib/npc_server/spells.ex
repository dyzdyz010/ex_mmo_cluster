defmodule NpcServer.Spells do
  @moduledoc """
  全局系统功能：NPC 的作者法术带（`profile.spells`）——登记时的解码与进入场景时的报价校验。
  依据：设计 TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md` v2.11 §2.4“NPC 法术”；
  决策稿 `docs/10-active/magic/2026-11-19-slice3-protocol.md` §7、§8（`npc_spell_rejected`）、P10。

  ## 数据形状

  - 注册表行（JSON）里：`"spells" => %{名字 => 小写十六进制}`，与目录 v5 `presets[].program_hex`、
    `ir-v2-samples.json` 同一种文字形式（不用 base64：同一程序在目录、样本和 NPC 里只有一种写法）。
  - 登记边界（`decode!/1`，由 `NpcServer.Registry.brain/2` 调用）一次解码成 `%{名字 => IR v2 字节}`；非法十六进制或
    空程序 raise，登记被拒。之后 profile、Abilities、Body、0x82 请求里只传字节。
  - 程序是否合法要看目录，目录在 World：登记时只能判十六进制，程序本身由下面的报价校验交给 World 判。

  ## 进入场景时的报价校验（P10）

  ```mermaid
  sequenceDiagram
    participant B as Body
    participant C as 校验进程（check/4 起，链接 Body）
    participant P as Player
    participant W as World
    B->>C: 会话就绪（收到 InputStart）
    C->>W: World.magic_digest/1
    alt digest 与上次校验相同
      C-->>C: 结束，不报价
    else 新目录（或首次）
      loop 每道法术（按名字排序）
        C->>P: Player.spell/5（0x82 action 0）
        P->>W: quote_cast
        W-->>C: {:ok, 0x83} | {:error, 原因}
      end
      C->>B: {:npc_spells_checked, digest, 被拒程序 => 原因}
    end
  ```

  - 走与玩家报价同一个入口 `Player.spell/5`（action 0 要求 Player 已 ready；InputStart 只在 ready 之后下发，所以 Body
    在收到它时才起校验）。每次会话就绪都起一次，但 World 目录 digest 与上次校验相同就不再报价。
  - 报价不瞄准任何东西：方向竖直向上、目标句柄全零（`NpcServer.WorldRequest.quote/2`）。
  - 判定（`verdict/1`）：
    - `rejects` 为空 → 可用。
    - `rejects` 非空，或 `:invalid_program` → **被拒**：打 `npc_spell_rejected`，Body 之后对这道程序的 `cast_spell`
      就地回 `{:spell_rejected, 原因}`，不再交给 World。
    - `:no_target` / `:stale_target` → 程序已过 World 的字节层与签名层（World 先解码、后求射线），但需要目标的
      〈取〉〈附〉在这里拿不到施放处，数值检查留到施放时由 World 判。记为 deferred，照常可用。
    - 其余（目录缺失、`:quote_rate` 重试后仍超频、超时等）→ unverified：打 `npc_spell_unverified`，照常可用，施放时
      仍由 World 裁决。校验只是提前发现坏程序，不是第二个权威。
  - 报价限频（目录 `quotas.quotes_per_caster_per_s`，World 按 1 s 滑动窗口判）：NPC 读不到这个目录字段，逐个同步报价，
    遇 `:quote_rate` 等 1 s（窗口长度）后对同一道法术重试一次。只有本 NPC 自己会为这个 cid 报价（施放不计入），
    所以重试必然进窗口；第二次仍超频就记 unverified。
  - 校验进程链接 Body：Body 结束时它随之结束；它的世界调用遇会话丢失（Player 已退出）就安静结束、不回结果，
    下一次会话就绪再校验；其余退出按执行进程同一规则上抛（代码缺陷照样崩溃）。

  可用集合目前只在 Body 生效：LLM 工具表的 `spell` 枚举取自建脑时的 profile（`Abilities` 约定 schema 只依赖 profile），
  被拒的名字仍会出现在枚举里，选中后得到 `spell_rejected`。从枚举里剔除要 Runtime 把结果交给 Brain，属后续工作。
  NPC 配额（每 NPC ≤ 4 个结构等，设计 §5.6、D8）属于切片 7，不在这里。
  """
  require Logger
  alias NpcServer.WorldRequest
  alias SceneServer.Movement.Player
  alias VoxelRegion.World

  # 报价限频的窗口长度（设计 §4.2 末段：每施法者每秒）；超频后等满一个窗口再重试。
  @quote_window_ms 1_000
  # 单次报价的等待上限：报价不改世界，World 只做一次计价；超时记 unverified，不让后台校验无限挂起。
  @quote_timeout_ms 30_000
  # 这些拒绝发生在 World 解码程序之后、只说明这次报价没有可用的施放处（决策稿 P13）。
  @deferred [:no_target, :stale_target]

  @typedoc "Body 持有的校验状态：作者法术带、最近一次完成校验的目录 digest（nil = 还没校验过）、被拒程序 => 原因。"
  @type state :: %{band: %{String.t() => binary()}, digest: binary() | nil, rejected: map()}

  @doc """
  注册表 JSON 的法术带 `%{名字 => 小写十六进制}` → `%{名字 => IR v2 字节}`。信任边界只在这里：任一道不是非空的
  小写十六进制就 raise `ArgumentError`（`Registry` 把它变成 `{:error, {:invalid_params, 说明}}`）。
  """
  @spec decode!(%{String.t() => String.t()}) :: %{String.t() => binary()}
  def decode!(spells) when is_map(spells), do: Map.new(spells, &decode_spell!/1)

  defp decode_spell!({name, hex}) when is_binary(name) and is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, <<_, _::binary>> = program} ->
        {name, program}

      _ ->
        raise ArgumentError,
              "法术 #{inspect(name)} 的程序必须是非空的小写十六进制（IR v2 字节），收到 #{inspect(hex, limit: 8, printable_limit: 64)}"
    end
  end

  @doc "Body 初始化时的校验状态：只记作者法术带，还没有 World 的判定。"
  @spec new(%{String.t() => binary()}) :: state()
  def new(band), do: %{band: band, digest: nil, rejected: %{}}

  @doc """
  会话就绪时起一次校验（见 moduledoc）。`session` 取 Body 的 `player`、`identity`、`world_ref`、`cid`、`scene_id`；
  `first_seq` 起连续分给各道法术作 request_id / client_intent_seq。返回占用的序号个数（法术带为空时不起进程，返回 0）。
  结果以 `{:npc_spells_checked, digest, rejected}` 发回 `body`。
  """
  @spec check(state(), pid(), map(), pos_integer()) :: non_neg_integer()
  def check(%{band: band}, _body, _session, _first_seq) when map_size(band) == 0, do: 0

  def check(%{band: band, digest: known}, body, session, first_seq) do
    spawn_link(fn -> run(band, known, body, session, first_seq) end)
    map_size(band)
  end

  @doc "记下一次完成的校验结果（`check/4` 发回的消息）。"
  @spec checked(state(), binary(), map()) :: state()
  def checked(state, digest, rejected), do: %{state | digest: digest, rejected: rejected}

  @doc """
  一次 action 0 报价的回复 → 判定：`:usable`、`{:deferred, 原因}`、`{:rejected, 原因}` 或 `{:unverified, 原因}`
  （含义见 moduledoc）。
  """
  def verdict({:ok, %{caster: %{rejects: []}}}), do: :usable
  def verdict({:ok, %{caster: %{rejects: names}}}), do: {:rejected, {:rejects, names}}
  def verdict({:error, :invalid_program}), do: {:rejected, :invalid_program}
  def verdict({:error, reason}) when reason in @deferred, do: {:deferred, reason}
  def verdict({:error, reason}), do: {:unverified, reason}

  # —— 校验进程 ——

  defp run(band, known, body, session, first_seq) do
    case world_call(session, fn -> World.magic_digest(session.world_ref) end) do
      :lost ->
        :ok

      nil ->
        Logger.warning("npc_spell_check npc=#{session.cid} result=no_magic_catalog")

      # 读 digest 超时（World 卡住）：这次不校验，下一次会话就绪再来；施放仍由 World 裁决。
      {:error, reason} ->
        Logger.warning(
          "npc_spell_check npc=#{session.cid} result=digest_failed reason=#{inspect(reason)}"
        )

      # 同一份目录已经校验过（重新 claim、Scene 重启但 World 未换目录）。
      ^known ->
        :ok

      digest ->
        band
        |> Enum.sort()
        |> Enum.with_index(first_seq)
        |> Enum.reduce_while([], fn {{name, program}, seq}, done ->
          case quote(session, digest, program, seq, 2) do
            :lost -> {:halt, :lost}
            result -> {:cont, [{name, program, verdict(result)} | done]}
          end
        end)
        |> report(body, session, digest)
    end
  end

  # 0x82 action 0：与玩家报价同一入口。成功的报价 World 还会把 0x83 发给 caster_recipient（这里是本进程，忽略即可，
  # 进程结束时随邮箱丢弃），不经 Body，所以不改 Observation 的 self.caster。
  defp quote(session, digest, program, seq, attempts) do
    {:voxel_spell_intent, request} =
      WorldRequest.quote(program, %{seq: seq, scene_id: session.scene_id})

    ingress = %{
      received_us: System.monotonic_time(:microsecond),
      clock_node: node(),
      caster_recipient: {self(), :npc_spell_check}
    }

    result =
      world_call(session, fn ->
        Player.spell(
          session.player,
          session.identity,
          %{request | catalog_digest: digest},
          ingress,
          @quote_timeout_ms
        )
      end)

    case result do
      {:error, :quote_rate} when attempts > 1 ->
        Process.sleep(@quote_window_ms)
        quote(session, digest, program, seq, attempts - 1)

      result ->
        result
    end
  end

  # 会话丢失途中：不回半份结果，下一次会话就绪再校验。
  defp report(:lost, _body, _session, _digest), do: :ok

  defp report(verdicts, body, session, digest) do
    verdicts = Enum.reverse(verdicts)

    for {name, program, {kind, reason}} <- verdicts, kind in [:rejected, :unverified] do
      Logger.warning(
        "npc_spell_#{kind} npc=#{session.cid} name=#{inspect(name)} program_sha=#{sha(program)} " <>
          "bytes=#{byte_size(program)} digest=#{short(digest)} reason=#{inspect(reason)}"
      )
    end

    names = fn wanted ->
      for {name, _, verdict} <- verdicts, kind(verdict) == wanted, do: name
    end

    Logger.info(
      "npc_spell_check npc=#{session.cid} digest=#{short(digest)} usable=#{inspect(names.(:usable))} " <>
        "deferred=#{inspect(names.(:deferred))} rejected=#{inspect(names.(:rejected))} " <>
        "unverified=#{inspect(names.(:unverified))}"
    )

    rejected = for {_, program, {:rejected, reason}} <- verdicts, into: %{}, do: {program, reason}
    send(body, {:npc_spells_checked, digest, rejected})
  end

  defp kind(:usable), do: :usable
  defp kind({kind, _reason}), do: kind

  # 与 Body 执行进程同一退出规则：Player 已退出 → :lost；报价超时 → {:error, :timeout}（unverified）；其余照常退出。
  # Scene 可在 peer 节点：判活用节点安全的 `Player.running?/1`。
  defp world_call(session, fun) do
    fun.()
  catch
    :exit, reason ->
      cond do
        not Player.running?(session.player) -> :lost
        match?({:timeout, _}, reason) -> {:error, :timeout}
        true -> exit(reason)
      end
  end

  # 日志只记程序身份（sha256 前 16 位十六进制）与字节数，不记程序全文（决策稿 §8）。
  defp sha(bytes),
    do: :crypto.hash(:sha256, bytes) |> binary_part(0, 8) |> Base.encode16(case: :lower)

  defp short(digest), do: digest |> binary_part(0, 8) |> Base.encode16(case: :lower)
end
