defmodule DevOrchestratorWeb.WebhookController do
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn
  alias DevOrchestrator.{Store, RateLimit}
  alias DevOrchestrator.Intake.{Signature, Linear}

  def receive_event(conn, %{"provider" => "linear", "connection_id" => id}) do
    connection =
      Store.one(
        "SELECT * FROM connections WHERE id=$1 AND provider='linear' AND revoked_at IS NULL",
        [id]
      )

    [signature] =
      case get_req_header(conn, "linear-signature") do
        [s] -> [s]
        _ -> [""]
      end

    raw = Map.get(conn.assigns, :raw_body, "")

    payload =
      case Jason.decode(raw) do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    secret = DevOrchestrator.Connections.OAuth.config("linear")[:webhook_secret]

    valid =
      connection &&
        Signature.valid_linear?(
          raw,
          signature,
          secret,
          payload["webhookTimestamp"],
          System.system_time(:millisecond)
        )

    if valid and RateLimit.check({:webhook, id}, 120) == :ok do
      delivery = Store.digest(raw)

      case Linear.receive_issue(connection, payload, delivery) do
        {:ok, _} -> json(conn, %{accepted: true})
        _ -> conn |> put_status(503) |> json(%{error: "temporarily_unavailable"})
      end
    else
      conn |> put_status(401) |> json(%{error: "invalid_webhook"})
    end
  end

  def receive_event(conn, _), do: conn |> put_status(404) |> json(%{error: "unsupported_webhook"})
end
