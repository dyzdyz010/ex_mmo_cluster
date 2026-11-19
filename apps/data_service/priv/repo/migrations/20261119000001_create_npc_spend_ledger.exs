defmodule DataService.Repo.Migrations.CreateNpcSpendLedger do
  use Ecto.Migration

  # NPC 模型花费的账本（花费额度决策稿 2026-11-18 §4.1 / §7）：一行一次模型调用，来源是产品回执（source = "product"）或
  # Hindsight 的 LLM 追踪行（source = "hindsight"，source_id 是追踪行 id、bank 是读回的库）。`unique(source, source_id)` 让重读
  # 同一行不重计；`day` 是按完成时刻归的北京自然日；`nano_usd` 为 null 表示模型不在价目表里（未定价）。
  def change do
    create table(:npc_spend_ledger) do
      add(:source, :string, null: false)
      add(:source_id, :string, null: false)
      add(:bank, :string)
      add(:operation, :string)
      add(:model, :string)
      add(:day, :date, null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec, null: false)
      add(:input_tokens, :bigint, null: false)
      add(:cached_tokens, :bigint, null: false)
      add(:output_tokens, :bigint, null: false)
      add(:thoughts_tokens, :bigint, null: false)
      add(:nano_usd, :bigint)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:npc_spend_ledger, [:source, :source_id]))
    create(index(:npc_spend_ledger, [:day]))
    create(index(:npc_spend_ledger, [:bank, :started_at]))
  end
end
