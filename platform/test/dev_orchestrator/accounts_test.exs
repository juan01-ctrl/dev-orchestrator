defmodule DevOrchestrator.AccountsTest do
  use DevOrchestrator.DataCase

  test "unverified users cannot sign in, and verified sessions are hashed and revocable" do
    {:ok, user} =
      Accounts.register(%{
        "email" => "unverified@example.test",
        "password" => "a-long-test-password"
      })

    assert {:error, :unverified} = Accounts.login(user.email, "a-long-test-password")
    DevOrchestrator.Store.exec("UPDATE users SET verified_at=now() WHERE id=$1", [user.id])
    {:ok, token} = Accounts.login(user.email, "a-long-test-password")
    assert {:ok, scope} = Accounts.from_session(token)
    assert scope.user_id == user.id

    row =
      DevOrchestrator.Store.one(
        "SELECT hash FROM account_tokens WHERE purpose='session' AND user_id=$1",
        [user.id]
      )

    refute row["hash"] == token
    Accounts.logout(token)
    assert {:error, :unauthenticated} = Accounts.from_session(token)
  end

  test "member permissions cannot enroll executors or disconnect connections" do
    scope = owner("member@example.test")

    DevOrchestrator.Store.exec("UPDATE memberships SET role='member' WHERE user_id=$1", [
      scope.user_id
    ])

    {:ok, member} = Accounts.scope(scope.user_id)
    assert {:error, :forbidden} = DevOrchestrator.Executors.create_enrollment(member)

    assert {:error, :forbidden} =
             DevOrchestrator.Connections.disconnect(member, "arbitrary-connection")
  end
end
