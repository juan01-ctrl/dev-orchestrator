defmodule DevOrchestrator.ProjectsTest do
  use DevOrchestrator.DataCase

  test "a guessed project ID does not authorize another organization" do
    alice = owner("alice@example.test")
    bob = owner("bob@example.test")

    {:ok, project} =
      Projects.create_project(alice, %{
        "name" => "Payments",
        "repository" => "acme/payments",
        "base_branch" => "main"
      })

    assert {:ok, %{id: id}} = Projects.get_project(alice, project.id)
    assert id == project.id
    assert {:error, :not_found} = Projects.get_project(bob, project.id)
    assert {:error, :not_found} = Projects.update_project(bob, project.id, %{"name" => "stolen"})
    assert [] = Projects.list(bob)
  end

  test "invalid branches and unverified users cannot configure projects" do
    scope = owner("owner@example.test")

    assert {:error, :invalid_project} =
             Projects.create_project(scope, %{
               "name" => "App",
               "repository" => "acme/app",
               "base_branch" => "../main"
             })

    DevOrchestrator.Store.exec("UPDATE users SET verified_at = NULL WHERE id = $1", [
      scope.user_id
    ])

    assert {:error, :unverified} = Accounts.scope(scope.user_id)
  end

  test "project snapshots are immutable values" do
    scope = owner("snapshot@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    snapshot = Projects.snapshot(project)
    {:ok, _} = Projects.update_project(scope, project.id, %{"base_branch" => "develop"})
    assert snapshot["base_branch"] == "main"
  end

  test "saving a Slack channel records its latest granted workspace" do
    scope = owner("slack-binding@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{
        "name" => "Slack intake",
        "repository" => "acme/slack-intake"
      })

    slack_connection(scope, project.id, "T_WORKSPACE", "slack-1")

    assert {:ok, updated} =
             Projects.update_project(scope, project.id, %{
               "slack_channel" => "C_TASKS",
               "slack_workspace_id" => "T_FORGED"
             })

    assert updated.data["slack_workspace_id"] == "T_WORKSPACE"
    assert Projects.snapshot(updated)["slack_workspace_id"] == "T_WORKSPACE"
  end

  test "the same workspace channel cannot belong to two projects" do
    scope = owner("slack-binding-unique@example.test")

    {:ok, first} = Projects.create_project(scope, %{"name" => "One", "repository" => "acme/one"})
    {:ok, second} = Projects.create_project(scope, %{"name" => "Two", "repository" => "acme/two"})
    slack_connection(scope, first.id, "T_WORKSPACE", "slack-1")
    slack_connection(scope, second.id, "T_WORKSPACE", "slack-2")

    assert {:ok, _} = Projects.update_project(scope, first.id, %{"slack_channel" => "C_TASKS"})

    assert {:error, :slack_channel_already_bound} =
             Projects.update_project(scope, second.id, %{"slack_channel" => "C_TASKS"})
  end

  test "the same channel ID may exist in different Slack workspaces" do
    scope = owner("slack-binding-workspaces@example.test")

    {:ok, first} = Projects.create_project(scope, %{"name" => "One", "repository" => "acme/one"})
    {:ok, second} = Projects.create_project(scope, %{"name" => "Two", "repository" => "acme/two"})
    slack_connection(scope, first.id, "T_ONE", "slack-1")
    slack_connection(scope, second.id, "T_TWO", "slack-2")

    assert {:ok, %{data: %{"slack_workspace_id" => "T_ONE"}}} =
             Projects.update_project(scope, first.id, %{"slack_channel" => "C_TASKS"})

    assert {:ok, %{data: %{"slack_workspace_id" => "T_TWO"}}} =
             Projects.update_project(scope, second.id, %{"slack_channel" => "C_TASKS"})
  end

  defp slack_connection(scope, project_id, workspace_id, id) do
    DevOrchestrator.Store.exec(
      "INSERT INTO connections(id,organization_id,provider,label,secret,external_id) VALUES($1,$2,'slack','Slack',decode('','hex'),$3)",
      [id, scope.organization_id, workspace_id]
    )

    DevOrchestrator.Store.exec("INSERT INTO connection_grants VALUES($1,$2,$3)", [
      scope.organization_id,
      project_id,
      id
    ])
  end

  test "project instructions accept only the named UTF-8 Markdown file within the size limit" do
    assert {:ok, "# Rules\n"} = Projects.validate_instructions("instructions.md", "# Rules\n")
    assert {:error, :invalid_filename} = Projects.validate_instructions("rules.md", "# Rules\n")

    assert {:error, :invalid_filename} =
             Projects.validate_instructions("instructions.txt", "# Rules\n")

    assert {:error, :invalid_encoding} =
             Projects.validate_instructions("instructions.md", <<255>>)

    assert {:error, :empty} = Projects.validate_instructions("instructions.md", "  \n")

    assert {:error, :too_large} =
             Projects.validate_instructions("instructions.md", :binary.copy("a", 32_001))
  end
end
