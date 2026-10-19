defmodule DevOrchestrator.Policy do
  @moduledoc "Validation shared by project configuration and trusted publication."

  def valid_branch?(branch) when is_binary(branch) do
    byte_size(branch) <= 200 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/, branch) and
      not String.contains?(branch, ["..", "//", "@{"]) and
      Enum.all?(String.split(branch, "/"), fn part ->
        part != "" and not String.starts_with?(part, ".") and
          not String.ends_with?(part, [".lock", "."])
      end)
  end

  def valid_branch?(_), do: false

  def valid_repository?(repo) when is_binary(repo) do
    byte_size(repo) <= 200 and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\/[A-Za-z0-9][A-Za-z0-9._-]*\z/, repo) and
      not String.ends_with?(repo, [".git", "."]) and not String.contains?(repo, "..")
  end

  def valid_repository?(_), do: false
end
