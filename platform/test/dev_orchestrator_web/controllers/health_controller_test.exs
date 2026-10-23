defmodule DevOrchestratorWeb.HealthControllerTest do
  use DevOrchestrator.DataCase
  import Phoenix.ConnTest

  @endpoint DevOrchestratorWeb.Endpoint

  test "readiness separates database, optional providers, executor, and queue health" do
    conn = get(build_conn(), "/api/v1/ready")

    assert %{"status" => "ready", "components" => components} = json_response(conn, 200)
    assert components["database"] == "ok"

    assert components["providers"] == %{
             "github" => "not_configured",
             "linear" => "not_configured",
             "slack" => "not_configured"
           }

    assert components["executor"] == "waiting"
    assert components["slack_audio_intake"] == "unconfigured"
    assert components["task_queue"] == "healthy"
    assert components["intake_queue"] == "healthy"
    assert components["delivery_queue"] == "healthy"
  end
end
