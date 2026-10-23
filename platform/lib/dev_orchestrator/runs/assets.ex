defmodule DevOrchestrator.Runs.Assets do
  @moduledoc false
  alias DevOrchestrator.{Store, Connections}
  alias DevOrchestrator.Connections.Linear

  def fetch(executor, lease, asset_id) when is_map(executor) and is_map(lease) do
    with {:ok, {connection, asset}} <- authorize(executor, lease, asset_id),
         {:ok, token} <- Connections.credential(connection),
         {:ok, file} <-
           Linear.download_file(token, asset["source_url"], filename_hint: asset["filename_hint"]) do
      {:ok, file}
    end
  end

  def fetch(_, _, _), do: {:error, :not_found}

  defp authorize(executor, lease, asset_id) when is_binary(asset_id) do
    Store.transaction(fn ->
      Store.one(
        "SELECT id FROM executors WHERE id=$1 AND organization_id=$2 AND revoked_at IS NULL",
        [executor["id"], executor["organization_id"]]
      ) || Store.halt(:unauthorized)

      run =
        Store.one("SELECT * FROM runs WHERE id=$1 AND organization_id=$2 FOR UPDATE", [
          lease["id"],
          executor["organization_id"]
        ]) || Store.halt(:not_found)

      if run["executor_id"] != executor["id"] or run["generation"] != lease["generation"] or
           run["lifecycle"] != lease["lifecycle"] or run["state"] not in ~w(leased running) or
           DateTime.compare(run["lease_expires_at"], DateTime.utc_now()) != :gt do
        Store.halt(:stale_lease)
      end

      Store.one(
        "SELECT project_id FROM executor_bindings WHERE executor_id=$1 AND project_id=$2 AND organization_id=$3",
        [executor["id"], run["project_id"], executor["organization_id"]]
      ) || Store.halt(:not_found)

      context = if is_map(run["source_context"]), do: run["source_context"], else: %{}

      asset =
        if(is_list(context["assets"]), do: context["assets"], else: [])
        |> Enum.find(fn
          %{"id" => id} when is_binary(id) -> id == asset_id
          _ -> false
        end) || Store.halt(:not_found)

      connection_id = context["linear_connection_id"]

      connection =
        Store.one(
          "SELECT c.* FROM connections c JOIN connection_grants g ON g.connection_id=c.id AND g.organization_id=c.organization_id WHERE c.id=$1 AND c.organization_id=$2 AND c.provider='linear' AND c.revoked_at IS NULL AND g.project_id=$3",
          [connection_id, executor["organization_id"], run["project_id"]]
        ) || Store.halt(:not_found)

      {connection, asset}
    end)
  end

  defp authorize(_, _, _), do: {:error, :not_found}
end
