defmodule DevOrchestrator.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias DevOrchestrator.{Accounts, Projects, Repo}
      import DevOrchestrator.DataCase
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(DevOrchestrator.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(DevOrchestrator.Repo, {:shared, self()})
    :ok
  end

  def owner(email) do
    {:ok, user} =
      DevOrchestrator.Accounts.register(%{
        "email" => email,
        "password" => "a-long-test-password",
        "name" => "Test team"
      })

    DevOrchestrator.Store.exec("UPDATE users SET verified_at = now() WHERE id = $1", [user.id])
    {:ok, scope} = DevOrchestrator.Accounts.scope(user.id)
    scope
  end
end
