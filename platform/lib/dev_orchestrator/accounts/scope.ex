defmodule DevOrchestrator.Accounts.Scope do
  @enforce_keys [:user_id, :organization_id, :role, :email]
  defstruct [:user_id, :organization_id, :role, :email]
end
