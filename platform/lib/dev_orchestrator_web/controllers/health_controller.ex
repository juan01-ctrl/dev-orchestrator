defmodule DevOrchestratorWeb.HealthController do
  use Phoenix.Controller, formats: [:json]
  def health(conn, _), do: json(conn, %{status: "ok", protocol: 1})

  def ready(conn, _) do
    DevOrchestrator.Store.exec("SELECT 1")
    json(conn, %{status: "ready"})
  rescue
    _ -> conn |> Plug.Conn.put_status(503) |> json(%{status: "not_ready"})
  end
end

defmodule DevOrchestratorWeb.ErrorHTML do
  def render(_template, _assigns), do: "The request could not be completed."
end

defmodule DevOrchestratorWeb.ErrorJSON do
  def render(_template, _assigns), do: %{error: "request_failed"}
end
