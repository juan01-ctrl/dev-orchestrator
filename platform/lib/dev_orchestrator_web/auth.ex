defmodule DevOrchestratorWeb.Auth do
  import Plug.Conn
  alias DevOrchestrator.Accounts

  def fetch_scope(conn, _) do
    case Accounts.from_session(get_session(conn, :session_token)) do
      {:ok, scope} -> assign(conn, :scope, scope)
      _ -> assign(conn, :scope, nil)
    end
  end

  def require_scope(%{assigns: %{scope: nil}} = conn, _),
    do: conn |> Phoenix.Controller.redirect(to: "/login") |> halt()

  def require_scope(conn, _), do: conn

  def on_mount(:required, _params, session, socket) do
    case Accounts.from_session(session["session_token"]) do
      {:ok, scope} -> {:cont, Phoenix.Component.assign(socket, :scope, scope)}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end
end
