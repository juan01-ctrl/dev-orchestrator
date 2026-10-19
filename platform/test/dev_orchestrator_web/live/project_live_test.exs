defmodule DevOrchestratorWeb.ProjectLiveTest do
  use DevOrchestrator.DataCase
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint DevOrchestratorWeb.Endpoint

  test "anonymous visitors are redirected away from project screens" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/app")
  end

  test "authenticated UI creates and displays a real project" do
    scope = owner("ui@example.test")
    {:ok, token} = Accounts.login(scope.email, "a-long-test-password")
    conn = build_conn() |> Plug.Test.init_test_session(%{session_token: token})
    {:ok, view, html} = live(conn, "/app")
    assert html =~ "Start with one project"

    view
    |> form("form[phx-submit=create_project]", %{
      "name" => "New app",
      "repository" => "acme/new-app",
      "base_branch" => "main"
    })
    |> render_submit()

    [project] = Projects.list(scope)
    assert_redirect(view, "/app/projects/" <> project.id)
  end
end
