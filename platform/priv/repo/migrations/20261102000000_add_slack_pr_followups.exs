defmodule DevOrchestrator.Repo.Migrations.AddSlackPRFollowups do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add(:followup_count, :integer, null: false, default: 0)
    end

    alter table(:slack_task_drafts) do
      add(:target_run_id, :text)
      add(:target_lifecycle, :integer)
      add(:target_commit, :text)
    end

    create table(:slack_run_threads, primary_key: false) do
      add(:organization_id, :text, primary_key: true)
      add(:project_id, :text, null: false)
      add(:run_id, :text, null: false)
      add(:lifecycle, :integer, null: false)
      add(:workspace_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:thread_ts, :text, primary_key: true)
      add(:requester_slack_user_id, :text)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      index(:slack_run_threads, [
        :organization_id,
        :run_id,
        :lifecycle,
        :workspace_id,
        :channel_id
      ])
    )

    create(
      unique_index(:slack_task_drafts, [:target_run_id],
        where:
          "target_run_id IS NOT NULL AND state IN ('received','processing','awaiting_confirmation','creating')",
        name: :one_open_slack_pr_followup
      )
    )

    execute(
      "ALTER TABLE slack_run_threads ADD CONSTRAINT slack_thread_run_scope FOREIGN KEY(organization_id,run_id) REFERENCES runs(organization_id,id) ON DELETE CASCADE",
      "ALTER TABLE slack_run_threads DROP CONSTRAINT slack_thread_run_scope"
    )

    execute(
      "ALTER TABLE slack_task_drafts ADD CONSTRAINT slack_draft_target_scope FOREIGN KEY(organization_id,target_run_id) REFERENCES runs(organization_id,id) ON DELETE CASCADE",
      "ALTER TABLE slack_task_drafts DROP CONSTRAINT slack_draft_target_scope"
    )

    execute(
      "ALTER TABLE slack_task_drafts ADD CONSTRAINT slack_draft_target_identity CHECK ((target_run_id IS NULL AND target_lifecycle IS NULL AND target_commit IS NULL) OR (target_run_id IS NOT NULL AND target_lifecycle IS NOT NULL AND target_commit IS NOT NULL))",
      "ALTER TABLE slack_task_drafts DROP CONSTRAINT slack_draft_target_identity"
    )
  end
end
