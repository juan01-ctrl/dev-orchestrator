defmodule DevOrchestrator.MailerStartupTest do
  use ExUnit.Case, async: false

  @runtime_env [
    {"PUBLIC_URL", "https://orchestrator.example"},
    {"SECRET_KEY_BASE", String.duplicate("s", 64)},
    {"CONNECTION_ENCRYPTION_KEY", Base.encode64(:crypto.strong_rand_bytes(32))},
    {"DATABASE_URL", "postgres://postgres:postgres@localhost/orchestrator"},
    {"MAIL_FROM", "accounts@example.com"},
    {"RESEND_API_KEY", "re_test_api_key"}
  ]

  test "production mailer uses Resend API and the Req client" do
    with_runtime_env(@runtime_env, fn ->
      config = Config.Reader.read!("config/runtime.exs", env: :prod)

      mailer =
        config
        |> Keyword.fetch!(:dev_orchestrator)
        |> Keyword.fetch!(DevOrchestrator.Mailer)

      client = config |> Keyword.fetch!(:swoosh) |> Keyword.fetch!(:api_client)

      assert mailer[:adapter] == Swoosh.Adapters.Resend
      assert mailer[:api_key] == "re_test_api_key"
      assert client == Swoosh.ApiClient.Req
      assert config[:dev_orchestrator][:mail_from] == "accounts@example.com"
      assert :ok == client.init()
    end)
  end

  test "local and test mailers do not start an HTTP API client" do
    for env <- [:dev, :test] do
      config = Config.Reader.read!("config/config.exs", env: env)
      client = config |> Keyword.fetch!(:swoosh) |> Keyword.fetch!(:api_client)

      assert client == false,
             "#{env} must not start an HTTP API client for local/test email adapters"
    end
  end

  test "production mailer refuses to start without a Resend API key" do
    runtime_env = Keyword.delete(@runtime_env, "RESEND_API_KEY")

    with_runtime_env(runtime_env, fn ->
      assert_raise KeyError, ~r/RESEND_API_KEY/, fn ->
        Config.Reader.read!("config/runtime.exs", env: :prod)
      end
    end)
  end

  defp with_runtime_env(env, fun) do
    previous = Map.new(@runtime_env, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      Enum.each(previous, fn {key, _value} -> System.delete_env(key) end)
      Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
