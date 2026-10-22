defmodule DevOrchestrator.RunsLifecycleTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Runs.Lifecycle

  @project %{
    "linear_team" => "team-1",
    "linear_project" => "project-1",
    "active_states" => ["Todo", "In Progress"]
  }

  test "issue eligibility is scoped to the configured team, optional project, and active states" do
    issue = %{"team" => %{"id" => "team-1"}, "project" => %{"id" => "project-1"}, "state" => %{"name" => "Todo"}}
    assert Lifecycle.eligible?(@project, issue)
    refute Lifecycle.eligible?(@project, put_in(issue, ["team", "id"], "other-team"))
    refute Lifecycle.eligible?(@project, put_in(issue, ["project", "id"], "other-project"))
    refute Lifecycle.eligible?(@project, put_in(issue, ["state", "name"], "Done"))
  end

  test "an empty project mapping accepts any project within the configured Linear team" do
    issue = %{"team" => %{"id" => "team-1"}, "project" => %{"id" => "another-project"}, "state" => %{"name" => "In Progress"}}
    assert Lifecycle.eligible?(Map.put(@project, "linear_project", nil), issue)
  end
end
