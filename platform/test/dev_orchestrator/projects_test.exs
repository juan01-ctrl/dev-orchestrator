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
