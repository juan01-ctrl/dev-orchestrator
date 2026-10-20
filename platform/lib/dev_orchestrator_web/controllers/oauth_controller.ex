defmodule DevOrchestratorWeb.OAuthController do
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias DevOrchestrator.Connections

  def install_start(conn, %{"project_id" => project_id}) do
    session = get_session(conn, :session_token)

    case Connections.start_github_installation(conn.assigns.scope, project_id, session) do
      {:ok, url} ->
        redirect(conn, external: url)

      {:error, :not_configured} ->
        conn
        |> put_flash(:error, "GitHub App setup is incomplete on the server.")
        |> redirect(to: project_location(project_id))

      {:error, :forbidden} ->
        conn
        |> put_flash(:error, "Only a workspace owner can install the GitHub App.")
        |> redirect(to: project_location(project_id))

      _ ->
        conn
        |> put_flash(:error, "Could not start GitHub App installation for this project.")
        |> redirect(to: project_location(project_id))
    end
  end

  def install_start(conn, _), do: redirect(conn, to: "/app/connections")

  def install_callback(conn, %{"state" => state, "installation_id" => installation_id} = params) do
    result =
      if params["setup_action"] in ["install", "update"] do
        Connections.complete_github_installation(
          conn.assigns.scope,
          state,
          installation_id,
          get_session(conn, :session_token)
        )
      else
        {:error, :invalid_state}
      end

    case result do
      {:ok, project_id} ->
        conn
        |> put_flash(
          :info,
          "GitHub App access verified for this repository. Connect GitHub to finish setup."
        )
        |> redirect(to: project_location(project_id))

      {:error, :installation_required} ->
        conn
        |> put_flash(
          :error,
          "The GitHub App does not have access to this repository. Add this repository to the installation and try again."
        )
        |> redirect(to: "/app/connections")

      {:error, :repository_changed} ->
        conn
        |> put_flash(
          :error,
          "The project's repository changed during installation. Start again from the project page."
        )
        |> redirect(to: "/app/connections")

      {:error, :not_configured} ->
        conn
        |> put_flash(:error, "GitHub App setup is incomplete on the server.")
        |> redirect(to: "/app/connections")

      _ ->
        conn
        |> put_flash(
          :error,
          "GitHub installation could not be verified. Start a new installation from the project page."
        )
        |> redirect(to: "/app/connections")
    end
  end

  def install_callback(conn, _), do: redirect(conn, to: "/app/connections")

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
           "The GitHub App does not have access to this repository. Install it for this project, then reconnect. Large installations require narrower repository access."}

        _ ->
          {:error, "Connection failed or expired. Start a new connection from your project."}
      end

    conn |> put_flash(kind, message) |> redirect(to: "/app/connections")
  end

  def callback(conn, _), do: redirect(conn, to: "/app/connections")

  defp project_location(project_id) when is_binary(project_id) do
    case Ecto.UUID.cast(project_id) do
      {:ok, id} -> "/app/projects/" <> id
      :error -> "/app/connections"
    end
  end

  defp project_location(_), do: "/app/connections"
end
