defmodule DevOrchestratorWeb.RenderTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "registration renders labeled real form controls and a CSRF token" do
    html =
      render_component(&DevOrchestratorWeb.AccountHTML.page/1,
        mode: "register",
        error: nil,
        message: nil,
        token: nil
      )

    assert html =~ "Create your workspace"
    assert html =~ "Workspace name"
    assert html =~ "_csrf_token"
    assert html =~ "autocomplete=\"new-password\""
    assert html =~ "minlength=\"12\""
  end

  test "the project screen shows an actionable empty state instead of fake runs" do
    html =
      render_component(&DevOrchestratorWeb.DashboardLive.render/1,
        scope: %{email: "test@example.test", role: "owner"},
        live_action: :projects,
        projects: [],
        runs: [],
        connections: [],
        executors: [],
        bindings: [],
        selected: nil,
        selected_run: nil,
        code: nil,
        events: [],
        deliveries: [],
        flash: %{}
      )

    assert html =~ "Start with one project"
    assert html =~ "Create project"
    assert html =~ "0</span>"
    refute html =~ "PR ready"
  end
end
