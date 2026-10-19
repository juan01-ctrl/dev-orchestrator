defmodule DevOrchestrator.ConnectionsTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.Connections

  test "unconfigured providers do not authorize or create fake connections" do
    scope = owner("oauth@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    assert {:error, :not_configured} =
             Connections.start_oauth(scope, "slack", project.id, "session")

    assert [] = Connections.list(scope)
  end

  test "callback state is session scoped and cannot be replayed" do
    scope = owner("state@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    state = DevOrchestrator.Store.token()

    DevOrchestrator.Store.exec(
      "INSERT INTO oauth_states VALUES($1,$2,$3,$4,'slack',$5,now()+interval '10 minutes')",
      [
        DevOrchestrator.Store.digest(state),
        scope.organization_id,
        scope.user_id,
        project.id,
        DevOrchestrator.Store.digest("right-session")
      ]
    )

    assert {:error, :invalid_state} =
             Connections.consume_state(scope, "slack", state, "wrong-session")

    assert {:ok, _} = Connections.consume_state(scope, "slack", state, "right-session")

    assert {:error, :invalid_state} =
             Connections.consume_state(scope, "slack", state, "right-session")
  end
end
