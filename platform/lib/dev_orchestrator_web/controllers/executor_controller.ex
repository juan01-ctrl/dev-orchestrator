defmodule DevOrchestratorWeb.ExecutorController do
  use Phoenix.Controller, formats: [:json]
  alias DevOrchestrator.{Executors, Runs, RateLimit}
  import Plug.Conn

  def enroll(conn, params) do
    with :ok <- RateLimit.check({:pair, conn.remote_ip}, 10),
         {:ok, result} <- Executors.enroll(params["code"], params) do
      json(conn, result)
    else
      _ -> conn |> put_status(401) |> json(%{error: "invalid_or_expired_code"})
    end
  end

  def heartbeat(conn, params),
    do:
      authenticated(conn, fn executor ->
        Executors.heartbeat(executor, params)
        {:ok, %{status: "connected"}}
      end)

  def claim(conn, _), do: authenticated(conn, &Runs.claim/1)
  def renew(conn, params), do: authenticated(conn, &Runs.renew(&1, params))

  def github_token(conn, %{"lease" => lease, "purpose" => purpose}) do
    authenticated(conn, fn executor ->
      case purpose do
        "checkout" -> Runs.github_token(executor, lease, :checkout)
        "publish" -> Runs.github_token(executor, lease, :publish)
        _ -> {:error, :invalid_purpose}
      end
    end)
  end

  def github_token(conn, _), do: conn |> put_status(422) |> json(%{error: "invalid_request"})

  def event(conn, %{"lease" => lease, "event" => event}),
    do: authenticated(conn, &Runs.append_event(&1, lease, event))

  def event(conn, _), do: conn |> put_status(422) |> json(%{error: "invalid_event"})

  def asset(conn, %{"lease" => lease, "asset_id" => asset_id}) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, executor} <- Executors.authenticate(token) do
      case Runs.asset(executor, lease, asset_id) do
        {:ok, file} ->
          filename =
            file.filename |> String.replace(~r/[^A-Za-z0-9._ -]/u, "_") |> String.slice(0, 120)

          conn
          |> put_resp_content_type(file.media_type)
          |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
          |> put_resp_header("x-dev-orchestrator-sha256", file.sha256)
          |> put_resp_header("x-dev-orchestrator-size", Integer.to_string(byte_size(file.body)))
          |> send_resp(200, file.body)

        {:error, reason} ->
          asset_error(conn, reason)
      end
    else
      _ -> conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  def asset(conn, _), do: conn |> put_status(422) |> json(%{error: "invalid_request"})

  def reconcile(conn, %{"lease" => lease, "journal" => journal}),
    do: authenticated(conn, &Runs.reconcile(&1, lease, journal))

  def reconcile(conn, _), do: conn |> put_status(422) |> json(%{error: "invalid_journal"})

  def clarification_request(conn, %{"lease" => lease} = params),
    do: authenticated(conn, &Runs.request_clarification(&1, lease, params))

  def clarification_request(conn, _),
    do: conn |> put_status(422) |> json(%{error: "invalid_clarification"})

  def clarification_status(conn, %{"lease" => lease, "id" => id}),
    do: authenticated(conn, &Runs.clarification_status(&1, lease, id))

  def clarification_status(conn, _),
    do: conn |> put_status(422) |> json(%{error: "clarification_not_found"})

  defp authenticated(conn, fun) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, executor} <- Executors.authenticate(token) do
      case fun.(executor) do
        {:ok, result} -> json(conn, %{data: result})
        {:error, reason} -> conn |> put_status(409) |> json(%{error: to_string(reason)})
      end
    else
      _ -> conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  defp asset_error(conn, :stale_lease),
    do: conn |> put_status(409) |> json(%{error: "stale_lease"})

  defp asset_error(conn, :file_too_large),
    do: conn |> put_status(422) |> json(%{error: "file_too_large"})

  defp asset_error(conn, :unsupported_file),
    do: conn |> put_status(422) |> json(%{error: "unsupported_file"})

  defp asset_error(conn, reason) when reason in [:provider_unavailable, :provider_rate_limit],
    do: conn |> put_status(503) |> json(%{error: "provider_unavailable"})

  defp asset_error(conn, _), do: conn |> put_status(404) |> json(%{error: "asset_not_found"})
end
