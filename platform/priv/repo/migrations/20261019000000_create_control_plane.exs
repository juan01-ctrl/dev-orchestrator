defmodule DevOrchestrator.Repo.Migrations.CreateControlPlane do
  use Ecto.Migration

  def up do
    sql = """
    CREATE TABLE users (
      id text PRIMARY KEY, email text NOT NULL UNIQUE, password_hash text NOT NULL,
      verified_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
    );
    CREATE TABLE organizations (id text PRIMARY KEY, name text NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
    CREATE TABLE memberships (
      organization_id text NOT NULL REFERENCES organizations(id), user_id text NOT NULL REFERENCES users(id),
      role text NOT NULL CHECK (role IN ('owner','member')), PRIMARY KEY (organization_id,user_id)
    );
    CREATE TABLE account_tokens (
      hash text PRIMARY KEY, user_id text NOT NULL REFERENCES users(id),
      purpose text NOT NULL CHECK (purpose IN ('verify','reset','session')), expires_at timestamptz NOT NULL
    );
    CREATE TABLE projects (
      id text PRIMARY KEY, organization_id text NOT NULL REFERENCES organizations(id),
      name text NOT NULL, repository text NOT NULL, base_branch text NOT NULL,
      instructions text NOT NULL DEFAULT '', model text,
      concurrency integer NOT NULL DEFAULT 1 CHECK (concurrency BETWEEN 1 AND 10),
      version integer NOT NULL DEFAULT 1, linear_team text, linear_project text,
      active_states jsonb NOT NULL DEFAULT '["Todo","In Progress"]', review_state text NOT NULL DEFAULT 'In Review',
      slack_channel text, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(organization_id,id)
    );
    CREATE TABLE connections (
      id text PRIMARY KEY, organization_id text NOT NULL REFERENCES organizations(id),
      provider text NOT NULL CHECK (provider IN ('github','linear','slack')),
      label text NOT NULL, secret bytea NOT NULL, external_id text, revoked_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(organization_id,id)
    );
    CREATE TABLE connection_grants (
      organization_id text NOT NULL, project_id text NOT NULL, connection_id text NOT NULL,
      PRIMARY KEY(project_id,connection_id),
      FOREIGN KEY(organization_id,project_id) REFERENCES projects(organization_id,id),
      FOREIGN KEY(organization_id,connection_id) REFERENCES connections(organization_id,id)
    );
    CREATE TABLE oauth_states (
      hash text PRIMARY KEY, organization_id text NOT NULL, user_id text NOT NULL,
      project_id text NOT NULL, provider text NOT NULL, session_hash text NOT NULL,
      expires_at timestamptz NOT NULL,
      FOREIGN KEY(organization_id,project_id) REFERENCES projects(organization_id,id),
      FOREIGN KEY(organization_id,user_id) REFERENCES memberships(organization_id,user_id)
    );
    CREATE TABLE executors (
      id text PRIMARY KEY, organization_id text NOT NULL REFERENCES organizations(id),
      name text NOT NULL, credential_hash text NOT NULL UNIQUE, revoked_at timestamptz,
      last_seen_at timestamptz, capabilities jsonb NOT NULL DEFAULT '{}',
      created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(organization_id,id)
    );
    CREATE TABLE enrollments (
      hash text PRIMARY KEY, organization_id text NOT NULL REFERENCES organizations(id), expires_at timestamptz NOT NULL
    );
    CREATE TABLE executor_bindings (
      organization_id text NOT NULL, executor_id text NOT NULL, project_id text NOT NULL,
      PRIMARY KEY(executor_id,project_id),
      FOREIGN KEY(organization_id,executor_id) REFERENCES executors(organization_id,id),
      FOREIGN KEY(organization_id,project_id) REFERENCES projects(organization_id,id)
    );
    CREATE TABLE runs (
      id text PRIMARY KEY, organization_id text NOT NULL, project_id text NOT NULL,
      source_key text NOT NULL, title text NOT NULL, prompt text NOT NULL, issue_url text,
      state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','leased','running','waiting_for_executor','blocked','succeeded','failed','cancelled')),
      lifecycle integer NOT NULL DEFAULT 1, generation integer NOT NULL DEFAULT 0,
      executor_id text, lease_expires_at timestamptz, sequence integer NOT NULL DEFAULT 0,
      snapshot jsonb, failures jsonb NOT NULL DEFAULT '{}', result jsonb,
      created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE(project_id,source_key), UNIQUE(organization_id,id),
      FOREIGN KEY(organization_id,project_id) REFERENCES projects(organization_id,id),
      FOREIGN KEY(organization_id,executor_id) REFERENCES executors(organization_id,id)
    );
    CREATE INDEX runs_dispatch ON runs(project_id,state,created_at);
    CREATE TABLE run_events (
      organization_id text NOT NULL, run_id text NOT NULL, lifecycle integer NOT NULL,
      generation integer NOT NULL, sequence integer NOT NULL, kind text NOT NULL,
      data jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY(run_id,lifecycle,generation,sequence),
      FOREIGN KEY(organization_id,run_id) REFERENCES runs(organization_id,id)
    );
    CREATE TABLE webhook_receipts (
      connection_id text NOT NULL REFERENCES connections(id), delivery_id text NOT NULL,
      received_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(connection_id,delivery_id)
    );
    CREATE TABLE outbox (
      id text PRIMARY KEY, organization_id text NOT NULL, project_id text NOT NULL,
      run_id text NOT NULL, lifecycle integer NOT NULL, kind text NOT NULL,
      payload jsonb NOT NULL, state text NOT NULL DEFAULT 'pending', attempts integer NOT NULL DEFAULT 0,
      claimed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE(run_id,lifecycle,kind),
      FOREIGN KEY(organization_id,project_id) REFERENCES projects(organization_id,id),
      FOREIGN KEY(organization_id,run_id) REFERENCES runs(organization_id,id)
    );
    """

    sql |> String.split(";", trim: true) |> Enum.each(&execute/1)
  end

  def down do
    for table <-
          ~w(outbox webhook_receipts run_events runs executor_bindings enrollments executors oauth_states connection_grants connections projects account_tokens memberships organizations users),
        do: execute("DROP TABLE " <> table)
  end
end
