defmodule DevOrchestratorWeb.HealthController do
  use Phoenix.Controller, formats: [:json]
  alias DevOrchestrator.{Connections, Store}

  def health(conn, _), do: json(conn, %{status: "ok", protocol: 1})

  def ready(conn, _) do
    Store.exec("SELECT 1")
    readiness = Store.one(readiness_query())

    json(conn, %{
      status: "ready",
      components: %{
        database: "ok",
        providers: %{
          github: provider_status("github"),
          linear: provider_status("linear"),
          slack: provider_status("slack")
        },
        slack_audio_intake: slack_audio_intake_status(readiness),
        executor: if(readiness["active_executors"] > 0, do: "connected", else: "waiting"),
        task_queue: queue_status(readiness["queued_runs"]),
        intake_queue: queue_status(readiness["pending_webhooks"], readiness["failed_webhooks"]),
        delivery_queue:
          queue_status(readiness["pending_deliveries"], readiness["delivery_incidents"])
      }
    })
  rescue
    _ ->
      conn
      |> Plug.Conn.put_status(503)
      |> json(%{status: "not_ready", components: %{database: "unavailable"}})
  end

  defp provider_status(provider),
    do: if(Connections.OAuth.configured?(provider), do: "configured", else: "not_configured")

  defp slack_audio_intake_status(readiness) do
    slack = Connections.OAuth.config("slack")

    configured =
      Connections.OAuth.configured?("slack") and is_binary(slack[:signing_secret]) and
        slack[:signing_secret] != "" and DevOrchestrator.Connections.OpenAI.configured?()

    cond do
      not configured ->
        "unconfigured"

      readiness["failed_slack_drafts"] > 0 or readiness["pending_slack_drafts"] > 100 ->
        "degraded"

      true ->
        "configured"
    end
  end

  defp queue_status(count, incidents \\ 0)

  defp queue_status(_count, incidents) when incidents > 0, do: "needs_attention"
  defp queue_status(count, _) when count > 100, do: "backlogged"
  defp queue_status(_, _), do: "healthy"

  defp readiness_query do
    """
    SELECT
      (SELECT count(*) FROM executors WHERE revoked_at IS NULL AND last_seen_at>now()-interval '45 seconds') AS active_executors,
      (SELECT count(*) FROM runs WHERE state='queued') AS queued_runs,
      (SELECT count(*) FROM webhook_inbox WHERE state='pending' AND next_attempt_at<=now()) AS pending_webhooks,
      (SELECT count(*) FROM webhook_inbox WHERE state='failed') AS failed_webhooks,
      (SELECT count(*) FROM outbox WHERE state='pending' AND next_attempt_at<=now()) AS pending_deliveries,
      (SELECT count(*) FROM outbox WHERE state IN ('ambiguous','failed')) AS delivery_incidents,
      (SELECT count(*) FROM slack_task_drafts WHERE state='creation_ambiguous' OR (state='failed' AND updated_at>now()-interval '1 day')) AS failed_slack_drafts,
      (SELECT count(*) FROM slack_task_drafts WHERE state IN ('received','processing','creating')) AS pending_slack_drafts
    """
  end
end

defmodule DevOrchestratorWeb.ErrorHTML do
  def render(_template, _assigns), do: "The request could not be completed."
end

defmodule DevOrchestratorWeb.ErrorJSON do
  def render(_template, _assigns), do: %{error: "request_failed"}
end
