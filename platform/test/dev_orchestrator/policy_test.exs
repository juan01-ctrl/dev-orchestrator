defmodule DevOrchestrator.PolicyTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.Policy

  test "branches reject traversal, option injection and unsafe Git ref syntax" do
    for bad <- [
          "../main",
          "main..other",
          "-main",
          "a//b",
          "a.lock",
          "a/@{x}",
          "x\ny",
          "a/.secret"
        ] do
      refute Policy.valid_branch?(bad)
    end

    assert Policy.valid_branch?("task/JUA-13")
  end

  test "repository identity is not a clone URL or shell command" do
    assert Policy.valid_repository?("acme/payments")

    for bad <- ["https://github.com/acme/app", "../../repo", "acme/a.git", "-a/b", "a/b;c"] do
      refute Policy.valid_repository?(bad)
    end
  end
end
