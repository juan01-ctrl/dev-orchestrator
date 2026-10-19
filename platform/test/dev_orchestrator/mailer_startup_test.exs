defmodule DevOrchestrator.MailerStartupTest do
  use ExUnit.Case, async: false

  test "mail configurations start without an unused HTTP API client" do
    previous = Application.fetch_env(:swoosh, :api_client)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:swoosh, :api_client, value)
        :error -> Application.delete_env(:swoosh, :api_client)
      end
    end)

    for env <- [:dev, :test, :prod] do
      config = Config.Reader.read!("config/config.exs", env: env)
      client = config |> Keyword.get(:swoosh, []) |> Keyword.get(:api_client)

      assert client == false,
             "#{env} must disable the HTTP API client for Local, Test and SMTP adapters"

      Application.put_env(:swoosh, :api_client, client)
      assert :ok == Swoosh.ApiClient.init()
    end
  end
end
