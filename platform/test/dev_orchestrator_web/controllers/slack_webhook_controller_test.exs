defmodule DevOrchestratorWeb.SlackWebhookControllerTest do
  use DevOrchestrator.DataCase
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  alias DevOrchestrator.Store

  @endpoint DevOrchestratorWeb.Endpoint

  setup do
    previous = Application.get_env(:dev_orchestrator, :slack, [])

    Application.put_env(
      :dev_orchestrator,
      :slack,
      Keyword.put(previous, :signing_secret, "slack-signing-secret")
    )

    on_exit(fn -> Application.put_env(:dev_orchestrator, :slack, previous) end)
    :ok
  end

  test "signed URL verification responds synchronously with the challenge" do
    body = Jason.encode!(%{"type" => "url_verification", "challenge" => "challenge-1"})
    conn = signed_post(body)

    assert %{"challenge" => "challenge-1"} = json_response(conn, 200)
  end

  test "bad signatures are rejected and never enqueue an event" do
    body = Jason.encode!(%{"type" => "event_callback", "event_id" => "Ev-1"})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-slack-signature", "v0=bad")
      |> put_req_header(
        "x-slack-request-timestamp",
        Integer.to_string(System.system_time(:second))
      )
      |> post("/api/v1/webhooks/slack", body)

    assert %{"error" => "invalid_webhook"} = json_response(conn, 401)

    assert Store.one("SELECT count(*) AS count FROM webhook_inbox WHERE provider='slack'")[
             "count"
           ] == 0
  end

  test "signed app mentions are acknowledged and durably deduplicated" do
    body =
      Jason.encode!(%{
        "type" => "event_callback",
        "event_id" => "Ev-2",
        "team_id" => "T1",
        "event" => %{
          "type" => "app_mention",
          "user" => "U1",
          "channel" => "C1",
          "ts" => "1.2",
          "text" => "<@BOT> hello"
        }
      })

    assert %{"accepted" => true} = signed_post(body) |> json_response(200)
    assert %{"accepted" => true} = signed_post(body) |> json_response(200)

    assert Store.one("SELECT count(*) AS count FROM webhook_inbox WHERE provider='slack'")[
             "count"
           ] == 1
  end

  defp signed_post(body) do
    timestamp = Integer.to_string(System.system_time(:second))
    base = "v0:" <> timestamp <> ":" <> body

    signature =
      "v0=" <>
        (:crypto.mac(:hmac, :sha256, "slack-signing-secret", base) |> Base.encode16(case: :lower))

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-slack-signature", signature)
    |> put_req_header("x-slack-request-timestamp", timestamp)
    |> post("/api/v1/webhooks/slack", body)
  end
end
