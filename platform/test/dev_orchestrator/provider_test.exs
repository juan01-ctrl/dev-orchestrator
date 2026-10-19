defmodule DevOrchestrator.ProviderTest do
  use ExUnit.Case, async: false
  alias DevOrchestrator.Connections.{HTTP, Slack, OAuth}

  setup do
    old = Application.get_env(:dev_orchestrator, :provider_transport)

    on_exit(fn ->
      if old,
        do: Application.put_env(:dev_orchestrator, :provider_transport, old),
        else: Application.delete_env(:dev_orchestrator, :provider_transport)
    end)

    :ok
  end

  test "ambiguous Slack transport failure is not eligible for blind retry" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn _ -> {:error, :timeout} end)
    assert :ambiguous = Slack.deliver("test-only-token", %{})

    Application.put_env(:dev_orchestrator, :provider_transport, fn _ ->
      {:ok, %{status: 200, body: %{"ok" => false, "error" => "invalid_auth"}}}
    end)

    assert :rejected = Slack.deliver("test-only-token", %{})
  end

  test "Linear token refresh sends the explicit grant and preserves expiry" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      assert opts[:url] == "https://api.linear.app/oauth/token"
      assert opts[:form][:grant_type] == "refresh_token"
      assert opts[:form][:refresh_token] == "test-refresh-token"

      {:ok,
       %{status: 200, body: %{"access_token" => "replacement-test-token", "expires_in" => 3600}}}
    end)

    now = System.system_time(:second)
    assert {:ok, %{"expires_at" => expires}} = OAuth.refresh("linear", "test-refresh-token")
    assert expires >= now + 3599
  end

  test "provider errors are classified without returning raw bodies or credentials" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn _ ->
      {:ok, %{status: 401, body: %{"secret" => "do-not-return"}}}
    end)

    assert {:error, :provider_authentication} = HTTP.request(:get, "https://api.github.com/user")
  end
end
