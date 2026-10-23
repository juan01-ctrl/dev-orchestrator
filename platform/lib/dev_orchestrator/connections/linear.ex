defmodule DevOrchestrator.Connections.Linear do
  alias DevOrchestrator.Connections.HTTP

  def issue_id_from_source_key("linear:" <> value) do
    case String.split(value, ":") do
      [issue_id, activation] when issue_id != "" ->
        case Integer.parse(activation) do
          {number, ""} when number > 0 -> {:ok, issue_id}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def issue_id_from_source_key(_), do: :error

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
