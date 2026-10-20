defmodule DevOrchestratorWeb.GitHubInstallControllerTest do
  use DevOrchestrator.DataCase
  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]
  @endpoint DevOrchestratorWeb.Endpoint

  setup do
    old_github = Application.get_env(:dev_orchestrator, :github)
    old_transport = Application.get_env(:dev_orchestrator, :provider_transport)
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    key_path =
      Path.join(
        System.tmp_dir!(),
        "github-controller-test-#{System.unique_integer([:positive])}.pem"
      )

    File.write!(key_path, pem)

    Application.put_env(:dev_orchestrator, :github,
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      app_id: "12345",
      app_slug: "test-app",
      private_key_path: key_path
    )

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
               "repositories" => [%{"full_name" => "acme/app"}]
             }
           }}
      end
    end)

    on_exit(fn ->
      if old_github,
        do: Application.put_env(:dev_orchestrator, :github, old_github),
        else: Application.delete_env(:dev_orchestrator, :github)

      if old_transport,
        do: Application.put_env(:dev_orchestrator, :provider_transport, old_transport),
        else: Application.delete_env(:dev_orchestrator, :provider_transport)

      File.rm(key_path)
    end)

    :ok
  end

  test "start redirects the owner to install the configured app" do
    scope = owner("github-install-route@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    conn = signed_in(scope)
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn =
      post(conn, "/connections/github/install/start", %{
        "project_id" => project.id,
        "_csrf_token" => csrf_token
      })

    assert conn.status == 302

    assert get_resp_header(conn, "location") |> hd() =~
             "https://github.com/apps/test-app/installations/new?state="
  end

  test "setup callback verifies the installation and returns to the project" do
    scope = owner("github-install-callback@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    {conn, session_token} = signed_in_with_token(scope)

    {:ok, install_url} =
      DevOrchestrator.Connections.start_github_installation(scope, project.id, session_token)

    state =
      install_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    conn =
      conn
      |> get(
        "/connections/github/install/callback?state=#{URI.encode_www_form(state)}&installation_id=42&setup_action=install"
      )

    assert redirected_to(conn) == "/app/projects/" <> project.id
    assert DevOrchestrator.Connections.github_status(scope, project.id) == :installed
  end

  test "setup callback rejects invalid state without changing installation status" do
    scope = owner("github-install-invalid-callback@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    conn =
      signed_in(scope)
      |> get(
        "/connections/github/install/callback?state=invalid&installation_id=42&setup_action=install"
      )

    assert redirected_to(conn) == "/app/connections"
    assert DevOrchestrator.Connections.github_status(scope, project.id) == :not_installed
  end

  defp signed_in(scope) do
    {conn, _token} = signed_in_with_token(scope)
    conn
  end

  defp signed_in_with_token(scope) do
    {:ok, token} = DevOrchestrator.Accounts.login(scope.email, "a-long-test-password")
    {build_conn() |> Plug.Test.init_test_session(%{session_token: token}), token}
  end
end
