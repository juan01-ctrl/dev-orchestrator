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
end
