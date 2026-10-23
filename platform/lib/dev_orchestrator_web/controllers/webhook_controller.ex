defmodule DevOrchestratorWeb.WebhookController do
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn
  require Logger
  alias DevOrchestrator.{Store, RateLimit}
  alias DevOrchestrator.Intake.{Signature, Linear}
  alias DevOrchestrator.Connections.Slack

  def receive_slack(conn, _params) do
    raw = Map.get(conn.assigns, :raw_body, "")
    signature = List.first(get_req_header(conn, "x-slack-signature"), "")
    timestamp = List.first(get_req_header(conn, "x-slack-request-timestamp"), "")
    secret = DevOrchestrator.Connections.OAuth.config("slack")[:signing_secret]

    cond do
      byte_size(raw) > 65_536 ->
        conn |> put_status(413) |> json(%{error: "payload_too_large"})

      not Signature.valid_slack?(raw, signature, timestamp, secret, System.system_time(:second)) ->
        conn |> put_status(401) |> json(%{error: "invalid_webhook"})

      RateLimit.check({:slack_webhook, conn.remote_ip}, 120) != :ok ->
        conn |> put_status(429) |> json(%{error: "rate_limited"})

      true ->
        accept_slack_payload(conn, raw)
    end
  end

  defp accept_slack_payload(conn, raw) do
    case decode_slack_payload(raw) do
      {:ok, %{"type" => "url_verification", "challenge" => challenge}}
      when is_binary(challenge) and byte_size(challenge) <= 2_000 ->
        json(conn, %{challenge: challenge})

      {:ok, %{"type" => "event_callback"}} ->
        case DevOrchestrator.Intake.Inbox.accept_slack(raw) do
          {:ok, _result} ->
            json(conn, %{accepted: true})

          {:error, :payload_too_large} ->
            conn |> put_status(413) |> json(%{error: "payload_too_large"})

          {:error, _} ->
            conn |> put_status(400) |> json(%{error: "invalid_webhook"})
        end

      {:ok, %{"type" => "block_actions"} = payload} ->
        case Slack.normalize_action(payload) do
          {:ok, action} -> acknowledge_action(conn, action)
          _ -> json(conn, %{text: "This task button is no longer available."})
        end

      {:ok, _} ->
        json(conn, %{accepted: true, ignored: true})

      _ ->
        conn |> put_status(400) |> json(%{error: "invalid_webhook"})
    end
  end

  defp decode_slack_payload(raw) do
    case Jason.decode(raw) do
      {:ok, payload} ->
        {:ok, payload}

      _ ->
        case URI.decode_query(raw)["payload"] do
          payload when is_binary(payload) -> Jason.decode(payload)
          _ -> {:error, :invalid_payload}
        end
    end
  end

  defp acknowledge_action(conn, %{"action_id" => "create_linear_task"} = action) do
    case DevOrchestrator.Intake.SlackDrafts.confirm(action) do
      {:ok, _} ->
        json(conn, %{})

      {:error, :forbidden} ->
        json(conn, %{
          response_type: "ephemeral",
          text: "Only the person who requested this task can confirm it."
        })

      {:error, :expired} ->
        json(conn, %{
          response_type: "ephemeral",
          text: "This task draft has expired. Please send a new request."
        })

      _ ->
        json(conn, %{text: "This task button is no longer available."})
    end
  end

  defp acknowledge_action(conn, %{"action_id" => "cancel_linear_task"} = action) do
    case DevOrchestrator.Intake.SlackDrafts.cancel(action) do
      {:ok, _} ->
        json(conn, %{})

      {:error, :forbidden} ->
        json(conn, %{
          response_type: "ephemeral",
          text: "Only the person who requested this task can cancel it."
        })

      {:error, :expired} ->
        json(conn, %{response_type: "ephemeral", text: "This task draft has expired."})

      _ ->
        json(conn, %{text: "This task button is no longer available."})
    end
  end

  def receive_linear(conn, _params) do
    raw = Map.get(conn.assigns, :raw_body, "")
    [signature] = (List.wrap(get_req_header(conn, "linear-signature")) ++ [""]) |> Enum.take(1)
    [delivery_id] = (List.wrap(get_req_header(conn, "linear-delivery")) ++ [""]) |> Enum.take(1)

    payload =
      case Jason.decode(raw) do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    timestamp =
      case payload["webhookTimestamp"] do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {number, ""} -> number
            _ -> 0
          end

        _ ->
          0
      end

    secret = DevOrchestrator.Connections.OAuth.config("linear")[:webhook_secret]
    now = System.system_time(:millisecond)

    valid =
      is_binary(delivery_id) and delivery_id != "" and
        Signature.valid_linear?(raw, signature, secret, timestamp, now)

    cond do
      byte_size(raw) > 65_536 ->
        conn |> put_status(413) |> json(%{error: "payload_too_large"})

      not valid ->
        conn |> put_status(401) |> json(%{error: "invalid_webhook"})

      RateLimit.check({:linear_webhook, conn.remote_ip}, 120) != :ok ->
        conn |> put_status(429) |> json(%{error: "rate_limited"})

      true ->
        case DevOrchestrator.Intake.Inbox.accept_linear(%{"linear-delivery" => delivery_id}, raw) do
          {:ok, _} ->
            conn |> put_status(202) |> json(%{accepted: true})

          {:error, :unsupported_event} ->
            json(conn, %{accepted: true, ignored: true})

          {:error, :payload_too_large} ->
            conn |> put_status(413) |> json(%{error: "payload_too_large"})

          _ ->
            conn |> put_status(400) |> json(%{error: "invalid_webhook"})
        end
    end
  end

  def receive_event(conn, %{"provider" => "linear", "connection_id" => id}) do
    Logger.warning(
      "Deprecated per-connection Linear webhook received; update to the generic endpoint."
    )

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
