defmodule DevOrchestrator.ProviderTest do
  use ExUnit.Case, async: false
  alias DevOrchestrator.Connections.{GitHub, HTTP, Slack, OAuth}

  setup do
    old = Application.get_env(:dev_orchestrator, :provider_transport)
    old_github = Application.get_env(:dev_orchestrator, :github)
    old_slack = Application.get_env(:dev_orchestrator, :slack)
    old_public_url = Application.get_env(:dev_orchestrator, :public_url)

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    key_path =
      Path.join(System.tmp_dir!(), "github-app-test-#{System.unique_integer([:positive])}.pem")

    File.write!(key_path, pem)

    Application.put_env(:dev_orchestrator, :github,
      app_id: "12345",
      private_key_path: key_path,
      app_slug: "test-app"
    )

    Application.put_env(:dev_orchestrator, :public_url, "http://localhost:4100")

    on_exit(fn ->
      if old,
        do: Application.put_env(:dev_orchestrator, :provider_transport, old),
        else: Application.delete_env(:dev_orchestrator, :provider_transport)

      if old_github,
        do: Application.put_env(:dev_orchestrator, :github, old_github),
        else: Application.delete_env(:dev_orchestrator, :github)

      if old_slack,
        do: Application.put_env(:dev_orchestrator, :slack, old_slack),
        else: Application.delete_env(:dev_orchestrator, :slack)

      if old_public_url,
        do: Application.put_env(:dev_orchestrator, :public_url, old_public_url),
        else: Application.delete_env(:dev_orchestrator, :public_url)

      File.rm(key_path)
    end)

    :ok
  end

  test "Slack authorization requests channel listing and message scopes" do
    Application.put_env(:dev_orchestrator, :slack, client_id: "test-client")

    url = OAuth.authorize_url("slack", "opaque-state")
    query = URI.decode_query(URI.parse(url).query)

    assert query["scope"] == "chat:write,channels:read,groups:read"
  end

  test "Slack channel picker lists only bot-accessible channels across pages" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      assert opts[:url] == "https://slack.com/api/conversations.list"
      assert {"authorization", "Bearer test-only-token"} in opts[:headers]
      assert opts[:params][:types] == "public_channel,private_channel"
      assert opts[:params][:exclude_archived] == "true"
      assert opts[:params][:limit] == 200

      case opts[:params][:cursor] do
        nil ->
          {:ok,
           %{
             status: 200,
             body: %{
               "ok" => true,
               "channels" => [
                 %{"id" => "C123", "name" => "general", "is_member" => true},
                 %{"id" => "C456", "name" => "not-joined", "is_member" => false}
               ],
               "response_metadata" => %{"next_cursor" => "next-page"}
             }
           }}

        "next-page" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "ok" => true,
               "channels" => [%{"id" => "G789", "name" => "private", "is_member" => true}],
               "response_metadata" => %{"next_cursor" => ""}
             }
           }}
      end
    end)

    assert {:ok, [%{id: "C123", name: "general"}, %{id: "G789", name: "private"}]} =
             Slack.channels("test-only-token")
  end

  test "Slack channel picker identifies a connection missing read scopes" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn _opts ->
      {:ok, %{status: 200, body: %{"ok" => false, "error" => "missing_scope"}}}
    end)

    assert {:error, :missing_scope} = Slack.channels("test-only-token")
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

  test "installation URL preserves opaque state for the GitHub setup callback" do
    assert {:ok, "https://github.com/apps/test-app/installations/new?state=a%2B%2Fb"} =
             GitHub.installation_url("a+/b")
  end

  test "verifies an installation and returns only metadata for the exact repository" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      case opts[:url] do
        "https://api.github.com/app/installations/42/access_tokens" ->
          assert opts[:method] == :post
          assert [{"authorization", "Bearer " <> jwt} | _] = opts[:headers]
          assert String.starts_with?(jwt, "eyJ")
          {:ok, %{status: 201, body: %{"token" => "test-installation-token"}}}

        "https://api.github.com/installation/repositories?per_page=100" ->
          assert {"authorization", "Bearer test-installation-token"} in opts[:headers]

          {:ok,
           %{
             status: 200,
             body: %{
               "total_count" => 1,
               "repositories" => [%{"full_name" => "acme/app"}]
             }
           }}
      end
    end)

    assert {:ok, %{installation_id: 42, account: "acme"}} =
             GitHub.verify_installation("42", "acme/app")
  end

  test "rejects an installation id that does not belong to the configured GitHub App" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      assert opts[:url] == "https://api.github.com/app/installations/987/access_tokens"
      {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
    end)

    assert {:error, :installation_required} = GitHub.verify_installation("987", "acme/app")
  end

  test "rejects an installation that cannot access the project's exact repository" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      case opts[:url] do
        "https://api.github.com/app/installations/42/access_tokens" ->
          {:ok, %{status: 201, body: %{"token" => "test-installation-token"}}}

        "https://api.github.com/installation/repositories?per_page=100" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "total_count" => 1,
               "repositories" => [%{"full_name" => "acme/another-repo"}]
             }
           }}
      end
    end)

    assert {:error, :installation_required} = GitHub.verify_installation("42", "acme/app")
  end

  test "rejects installations whose repository access list exceeds the supported boundary" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      case opts[:url] do
        "https://api.github.com/app/installations/42/access_tokens" ->
          {:ok, %{status: 201, body: %{"token" => "test-installation-token"}}}

        "https://api.github.com/installation/repositories?per_page=100" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "total_count" => 101,
               "repositories" => [%{"full_name" => "acme/app"}]
             }
           }}
      end
    end)

    assert {:error, :installation_required} = GitHub.verify_installation("42", "acme/app")
  end

  test "mints checkout installation tokens for exactly one repository with read-only contents" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      assert opts[:url] == "https://api.github.com/app/installations/42/access_tokens"
      assert opts[:method] == :post
      assert opts[:json] == %{
               repositories: ["acme/app"],
               permissions: %{contents: "read"}
             }

      {:ok,
       %{status: 201, body: %{"token" => "ephemeral-checkout-token", "expires_at" => "2099-01-01T00:00:00Z"}}}
    end)

    assert {:ok, %{token: "ephemeral-checkout-token", expires_at: "2099-01-01T00:00:00Z"}} =
             GitHub.installation_token(42, "acme/app", :checkout)
  end

  test "mints publish installation tokens with only contents and pull request write access" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      assert opts[:json] == %{
               repositories: ["acme/app"],
               permissions: %{contents: "write", pull_requests: "write"}
             }

      {:ok, %{status: 201, body: %{"token" => "ephemeral-publish-token", "expires_at" => "2099-01-01T00:00:00Z"}}}
    end)

    assert {:ok, %{token: "ephemeral-publish-token"}} =
             GitHub.installation_token(42, "acme/app", :publish)
  end

  test "installation token errors do not expose provider bodies or credentials" do
    Application.put_env(:dev_orchestrator, :provider_transport, fn _ ->
      {:ok, %{status: 422, body: %{"message" => "do-not-return-this"}}}
    end)

    assert {:error, :provider_rejected} = GitHub.installation_token(42, "acme/app", :checkout)
  end
end
