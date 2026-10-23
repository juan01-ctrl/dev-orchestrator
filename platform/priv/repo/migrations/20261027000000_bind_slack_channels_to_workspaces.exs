defmodule DevOrchestrator.Repo.Migrations.BindSlackChannelsToWorkspaces do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add(:slack_workspace_id, :text)
    end

    execute("""
    WITH candidates AS (
      SELECT DISTINCT ON (p.id) p.id AS project_id, p.organization_id,
             c.external_id AS workspace_id, p.slack_channel
      FROM projects p
      JOIN connection_grants g ON g.project_id=p.id AND g.organization_id=p.organization_id
      JOIN connections c ON c.id=g.connection_id AND c.organization_id=g.organization_id
      WHERE p.slack_channel IS NOT NULL AND c.provider='slack'
        AND c.revoked_at IS NULL AND c.external_id IS NOT NULL
      ORDER BY p.id, c.created_at DESC, c.id DESC
    ), unambiguous AS (
      SELECT organization_id, workspace_id, slack_channel
      FROM candidates
      GROUP BY organization_id, workspace_id, slack_channel
      HAVING count(*) = 1
    )
    UPDATE projects p SET slack_workspace_id = c.workspace_id
    FROM candidates c
    JOIN unambiguous u ON u.organization_id=c.organization_id
      AND u.workspace_id=c.workspace_id AND u.slack_channel=c.slack_channel
    WHERE p.id=c.project_id
    """)

    create(
      unique_index(:projects, [:organization_id, :slack_workspace_id, :slack_channel],
        name: :projects_slack_workspace_channel_unique,
        where: "slack_workspace_id IS NOT NULL AND slack_channel IS NOT NULL"
      )
    )
  end

  def down do
    drop(index(:projects, name: :projects_slack_workspace_channel_unique))

    alter table(:projects) do
      remove(:slack_workspace_id)
    end
  end
end
