defmodule DevOrchestratorWeb.ExecutorControllerTest do
  use DevOrchestrator.DataCase
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  alias DevOrchestrator.{Executors, Runs, Store}

  @endpoint DevOrchestratorWeb.Endpoint

  setup do
    scope = owner("executor-token@example.test")
    {:ok, project} = Projects.create_project(scope, %{"name" => "App", "repository" => "acme/app"})
    {:ok, enrollment} = Executors.create_enrollment(scope)
    {:ok, %{token: token}} = Executors.enroll(enrollment, %{"name" => "Runner"})
    {:ok, executor} = Executors.authenticate(token)
    :ok = Executors.bind(scope, executor["id"], project.id)
    {:ok, _} = Runs.create(scope, project.id, %{"title" => "Task", "prompt" => "Edit"})
    {:ok, lease} = Runs.claim(executor)

    Store.exec(
      "INSERT INTO github_app_installations(organization_id,project_id,repository,installation_id,account) VALUES($1,$2,$3,$4,$5)",
      [scope.organization_id, project.id, "acme/app", 42, "acme"]
    )

    %{executor_token: token, lease: lease}
  end

  test "GitHub token endpoint requires executor authentication", ctx do
    conn = post(build_conn(), "/api/v1/executor/github-token", %{"lease" => ctx.lease, "purpose" => "checkout"})
    assert conn.status == 401
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GitHub token endpoint rejects unsupported purposes without calling the provider", ctx do
    Application.put_env(:dev_orchestrator, :provider_transport, fn _ -> flunk("provider must not be called") end)

    conn = authorized_post(ctx, %{"lease" => ctx.lease, "purpose" => "admin"})
    assert conn.status == 409
    assert json_response(conn, 409) == %{"error" => "invalid_purpose"}
  end

  test "GitHub token endpoint returns a scoped credential only for the active lease", ctx do
    old_github = Application.get_env(:dev_orchestrator, :github)
    old_transport = Application.get_env(:dev_orchestrator, :provider_transport)
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    key_path = Path.join(System.tmp_dir!(), "executor-github-#{System.unique_integer([:positive])}.pem")
    File.write!(key_path, pem)

    Application.put_env(:dev_orchestrator, :github,
      app_id: "12345",
      app_slug: "test-app",
      private_key_path: key_path
    )

    Application.put_env(:dev_orchestrator, :provider_transport, fn opts ->
      assert opts[:json] == %{repositories: ["acme/app"], permissions: %{contents: "read"}}

      {:ok, %{status: 201, body: %{"token" => "short-lived-token", "expires_at" => "2099-01-01T00:00:00Z"}}}
    end)

    on_exit(fn ->
      if old_github, do: Application.put_env(:dev_orchestrator, :github, old_github), else: Application.delete_env(:dev_orchestrator, :github)
      if old_transport, do: Application.put_env(:dev_orchestrator, :provider_transport, old_transport), else: Application.delete_env(:dev_orchestrator, :provider_transport)
      File.rm(key_path)
    end)

    conn = authorized_post(ctx, %{"lease" => ctx.lease, "purpose" => "checkout"})
    assert conn.status == 200

    assert %{"data" => %{
             "token" => "short-lived-token",
             "expires_at" => "2099-01-01T00:00:00Z",
             "author_name" => "test-app[bot]",
             "author_email" => "12345+test-app[bot]@users.noreply.github.com"
           }} = json_response(conn, 200)
  end

  test "GitHub provider errors are returned as stable codes without provider details", ctx do
    old_github = Application.get_env(:dev_orchestrator, :github)
    old_transport = Application.get_env(:dev_orchestrator, :provider_transport)
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    key_path = Path.join(System.tmp_dir!(), "executor-github-#{System.unique_integer([:positive])}.pem")
    File.write!(key_path, pem)

    Application.put_env(:dev_orchestrator, :github,
      app_id: "12345",
      app_slug: "test-app",
      private_key_path: key_path
    )

    Application.put_env(:dev_orchestrator, :provider_transport, fn _ ->
      {:ok, %{status: 422, body: %{"message" => "sensitive provider response"}}}
    end)

    on_exit(fn ->
      if old_github, do: Application.put_env(:dev_orchestrator, :github, old_github), else: Application.delete_env(:dev_orchestrator, :github)
      if old_transport, do: Application.put_env(:dev_orchestrator, :provider_transport, old_transport), else: Application.delete_env(:dev_orchestrator, :provider_transport)
      File.rm(key_path)
    end)

    conn = authorized_post(ctx, %{"lease" => ctx.lease, "purpose" => "checkout"})
    assert conn.status == 409
    assert json_response(conn, 409) == %{"error" => "provider_rejected"}
    refute conn.resp_body =~ "sensitive provider response"
  end

  defp authorized_post(ctx, payload) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.executor_token)
    |> post("/api/v1/executor/github-token", payload)
  end
end
