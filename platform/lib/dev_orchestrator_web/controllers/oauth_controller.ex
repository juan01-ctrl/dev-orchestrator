defmodule DevOrchestratorWeb.OAuthController do
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias DevOrchestrator.Connections

  def start(conn, %{"provider" => provider, "project_id" => project}) do
    session = get_session(conn, :session_token)

    case Connections.start_oauth(conn.assigns.scope, provider, project, session) do
      {:ok, url} ->
        redirect(conn, external: url)

      _ ->
        conn
        |> put_flash(
          :error,
          "Connection unavailable. Check owner access and provider application configuration."
        )
        |> redirect(to: "/app/connections")
    end
  end

  def start(conn, _), do: redirect(conn, to: "/app/connections")

  def callback(conn, %{"provider" => provider} = params) do
    result =
      Connections.complete_oauth(
        conn.assigns.scope,
        provider,
        params["state"],
        params["code"],
        get_session(conn, :session_token)
      )

    {kind, message} =
      case result do
        {:ok, _} ->
          {:info, "Account connected to the selected project."}

        {:error, :installation_required} ->
          {:error,
           "Install the configured GitHub App for this repository, then reconnect. Large installations require narrower repository access."}

        _ ->
          {:error, "Connection failed or expired. Start a new connection from your project."}
      end

    conn |> put_flash(kind, message) |> redirect(to: "/app/connections")
  end
end
