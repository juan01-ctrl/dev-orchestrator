defmodule DevOrchestrator.ConnectionsTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.Connections

  setup do
    old_github = Application.get_env(:dev_orchestrator, :github)
    old_transport = Application.get_env(:dev_orchestrator, :provider_transport)
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    key_path =
      Path.join(
        System.tmp_dir!(),
        "github-install-test-#{System.unique_integer([:positive])}.pem"
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

  test "unconfigured providers do not authorize or create fake connections" do
    scope = owner("oauth@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    assert {:error, :not_configured} =
             Connections.start_oauth(scope, "slack", project.id, "session")

    assert [] = Connections.list(scope)
  end

  test "callback state is session scoped and cannot be replayed" do
    scope = owner("state@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    state = DevOrchestrator.Store.token()

    DevOrchestrator.Store.exec(
      "INSERT INTO oauth_states VALUES($1,$2,$3,$4,'slack',$5,now()+interval '10 minutes')",
      [
        DevOrchestrator.Store.digest(state),
        scope.organization_id,
        scope.user_id,
        project.id,
        DevOrchestrator.Store.digest("right-session")
      ]
    )

    assert {:error, :invalid_state} =
             Connections.consume_state(scope, "slack", state, "wrong-session")

    assert {:ok, _} = Connections.consume_state(scope, "slack", state, "right-session")

    assert {:error, :invalid_state} =
             Connections.consume_state(scope, "slack", state, "right-session")
  end

  test "GitHub install flow verifies owner session and repository before saving installation" do
    scope = owner("github-install@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    assert {:ok, install_url} =
             Connections.start_github_installation(scope, project.id, "browser-session")

    uri = URI.parse(install_url)
    query = URI.decode_query(uri.query)
    assert uri.host == "github.com"
    assert uri.path == "/apps/test-app/installations/new"
    assert is_binary(query["state"])

    assert {:error, :invalid_state} =
             Connections.complete_github_installation(
               scope,
               query["state"],
               "42",
               "different-session"
             )

    assert {:ok, project_id} =
             Connections.complete_github_installation(
               scope,
               query["state"],
               "42",
               "browser-session"
             )

    assert project_id == project.id

    assert :installed = Connections.github_status(scope, project.id)

    assert {:error, :invalid_state} =
             Connections.complete_github_installation(
               scope,
               query["state"],
               "42",
               "browser-session"
             )
  end

  test "GitHub installation cannot be completed after the project's repository changes" do
    scope = owner("github-repo-change@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    assert {:ok, install_url} =
             Connections.start_github_installation(scope, project.id, "browser-session")

    state =
      install_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    assert {:ok, _} =
             Projects.update_project(scope, project.id, %{"repository" => "acme/renamed"})

    assert {:error, :repository_changed} =
             Connections.complete_github_installation(scope, state, "42", "browser-session")

    assert :not_installed = Connections.github_status(scope, project.id)
  end

  test "expired GitHub installation state is rejected without provider access" do
    scope = owner("github-expired-state@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    {:ok, install_url} =
      Connections.start_github_installation(scope, project.id, "browser-session")

    state =
      install_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    DevOrchestrator.Store.exec(
      "UPDATE github_install_states SET expires_at=now()-interval '1 second' WHERE hash=$1",
      [DevOrchestrator.Store.digest(state)]
    )

    assert {:error, :invalid_state} =
             Connections.complete_github_installation(scope, state, "42", "browser-session")
  end

  test "a GitHub App update that removes repository access clears the verified status" do
    scope = owner("github-access-removed@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    DevOrchestrator.Store.exec(
      "INSERT INTO github_app_installations(organization_id,project_id,repository,installation_id,account) VALUES($1,$2,$3,$4,$5)",
      [scope.organization_id, project.id, "acme/app", 42, "acme"]
    )

    {:ok, install_url} =
      Connections.start_github_installation(scope, project.id, "browser-session")

    state =
      install_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

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

    assert {:error, :installation_required} =
             Connections.complete_github_installation(scope, state, "42", "browser-session")

    assert :not_installed = Connections.github_status(scope, project.id)
  end

  test "only an owner can start GitHub installation and projects are tenant scoped" do
    scope = owner("github-owner@example.test")

    {:ok, project} =
      Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})

    DevOrchestrator.Store.exec(
      "UPDATE memberships SET role='member' WHERE organization_id=$1 AND user_id=$2",
      [scope.organization_id, scope.user_id]
    )

    {:ok, member_scope} = DevOrchestrator.Accounts.scope(scope.user_id)

    assert {:error, :forbidden} =
             Connections.start_github_installation(member_scope, project.id, "session")

    other_scope = owner("github-other@example.test")

    assert {:error, :not_found} =
             Connections.start_github_installation(other_scope, project.id, "session")
  end
end
