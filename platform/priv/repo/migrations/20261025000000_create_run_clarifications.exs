defmodule DevOrchestrator.Repo.Migrations.CreateRunClarifications do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE run_clarifications (
      id text PRIMARY KEY,
      organization_id text NOT NULL,
      project_id text NOT NULL,
      run_id text NOT NULL,
      lifecycle integer NOT NULL,
      generation integer NOT NULL,
      request_key text NOT NULL,
      status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','answered','expired')),
      questions jsonb NOT NULL,
      answer jsonb,
      created_at timestamptz NOT NULL DEFAULT now(),
      expires_at timestamptz NOT NULL,
      answered_at timestamptz,
      FOREIGN KEY (organization_id, project_id) REFERENCES projects(organization_id, id),
      FOREIGN KEY (organization_id, run_id) REFERENCES runs(organization_id, id)
    )
    """)

    execute("""
    CREATE UNIQUE INDEX run_clarifications_one_open
    ON run_clarifications(run_id, lifecycle, generation) WHERE status = 'open'
    """)

    execute(
      "CREATE UNIQUE INDEX run_clarifications_request ON run_clarifications(run_id,lifecycle,generation,request_key)"
    )

    execute(
      "CREATE INDEX run_clarifications_recent ON run_clarifications(run_id,created_at DESC)"
    )
  end

  def down do
    execute("DROP INDEX run_clarifications_recent")
    execute("DROP INDEX run_clarifications_request")
    execute("DROP INDEX run_clarifications_one_open")
    execute("DROP TABLE run_clarifications")
  end
end
