defmodule DevOrchestrator.Connections.Linear do
  alias DevOrchestrator.Connections.HTTP

  def query(token, query, variables) when is_binary(token) do
    case HTTP.request(:post, "https://api.linear.app/graphql",
           headers: [{"authorization", "Bearer " <> token}],
           json: %{query: query, variables: variables}
         ) do
      {:ok, %{"errors" => _}} -> {:error, :provider_rejected}
      other -> other
    end
  end
end
