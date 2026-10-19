defmodule DevOrchestrator.Store do
  @moduledoc false
  alias DevOrchestrator.Repo

  def rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, params)

    Enum.map(rows || [], fn row ->
      Map.new(Enum.zip(columns, row), fn {key, value} -> {key, value} end)
    end)
  end

  def one(sql, params \\ []), do: rows(sql, params) |> List.first()
  def exec(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
  def id, do: Ecto.UUID.generate()
  def token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  def digest(token) when is_binary(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  def transaction(fun), do: Repo.transaction(fun)
  def halt(reason), do: Repo.rollback(reason)
end
