defmodule DevOrchestrator.Repo.Migrations.CreateGithubAppInstallations do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE github_install_states (
      hash text PRIMARY KEY,
      organization_id text NOT NULL,
      user_id text NOT NULL,
      project_id text NOT NULL,
      repository text NOT NULL,
      session_hash text NOT NULL,
      expires_at timestamptz NOT NULL,
      FOREIGN KEY (organization_id, project_id) REFERENCES projects(organization_id, id),
      FOREIGN KEY (organization_id, user_id) REFERENCES memberships(organization_id, user_id)
    )
    """)

    execute("""
    CREATE TABLE github_app_installations (
      organization_id text NOT NULL,
      project_id text NOT NULL,
      repository text NOT NULL,
      installation_id bigint NOT NULL,
      account text NOT NULL,
      verified_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (organization_id, project_id),
      FOREIGN KEY (organization_id, project_id) REFERENCES projects(organization_id, id)
    )
    """)
  end

  def down do
    execute("DROP TABLE github_app_installations")
    execute("DROP TABLE github_install_states")
  end
end
