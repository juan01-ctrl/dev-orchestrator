defmodule DevOrchestrator.Connections.HTTP do
  @moduledoc false
  def request(method, url, opts \\ []) do
    transport = Application.get_env(:dev_orchestrator, :provider_transport, &Req.request/1)

    transport.(
      [method: method, url: url, redirect: false, retry: false, receive_timeout: 15_000] ++ opts
    )
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} when status in [401, 403] -> {:error, :provider_authentication}
      {:ok, %{status: 429}} -> {:error, :provider_rate_limit}
      {:ok, _} -> {:error, :provider_rejected}
      _ -> {:error, :provider_unavailable}
    end
  end
end
