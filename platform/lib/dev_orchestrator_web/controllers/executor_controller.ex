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
end
