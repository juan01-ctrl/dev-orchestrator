defmodule DevOrchestratorWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :dev_orchestrator

  @session_options [
    store: :cookie,
    key: "_dev_orchestrator",
    signing_salt: "session-signing",
    encryption_salt: "session-encryption",
    same_site: "Lax",
    http_only: true
  ]
  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])
  plug(Plug.Static,
    at: "/",
    from: :dev_orchestrator,
    only: ~w(assets templates)
  )
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 65_536,
    body_reader: {DevOrchestratorWeb.RawBody, :read_body, []}
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(:session)
  plug(DevOrchestratorWeb.Router)

  defp session(conn, _) do
    opts =
      Keyword.put(
        @session_options,
        :secure,
        Application.get_env(:dev_orchestrator, :secure_cookies, true)
      )

    Plug.Session.call(conn, Plug.Session.init(opts))
  end
end


defmodule DevOrchestratorWeb.RawBody do
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
      other -> other
    end
  end
end
