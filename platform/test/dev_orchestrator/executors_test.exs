defmodule DevOrchestrator.ExecutorsTest do
  use DevOrchestrator.DataCase
  alias DevOrchestrator.Executors

  test "enrollment is single use and credentials are revocable" do
    scope = owner("executor@example.test")
    {:ok, code} = Executors.create_enrollment(scope)
    assert {:ok, %{token: token}} = Executors.enroll(code, %{"name" => "My Mac"})
    assert {:error, :invalid_code} = Executors.enroll(code, %{"name" => "Replay"})
    assert {:ok, executor} = Executors.authenticate(token)
    refute executor["credential_hash"] == token
    assert :ok = Executors.revoke(scope, executor["id"])
    assert {:error, :unauthorized} = Executors.authenticate(token)
  end

  test "expired codes and cross-tenant bindings are rejected" do
    alice = owner("executor-alice@example.test")
    bob = owner("executor-bob@example.test")
    {:ok, code} = Executors.create_enrollment(alice)
    DevOrchestrator.Store.exec("UPDATE enrollments SET expires_at=now()-interval '1 second'")
    assert {:error, :invalid_code} = Executors.enroll(code, %{"name" => "Expired"})
    {:ok, code} = Executors.create_enrollment(alice)
    {:ok, %{token: token}} = Executors.enroll(code, %{"name" => "Alice Mac"})
    {:ok, executor} = Executors.authenticate(token)

    {:ok, project} =
      Projects.create_project(bob, %{"name" => "Private", "repository" => "acme/private"})

    assert {:error, :not_found} = Executors.bind(alice, executor["id"], project.id)
  end
end
