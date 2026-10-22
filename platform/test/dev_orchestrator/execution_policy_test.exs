defmodule DevOrchestrator.ExecutionPolicyTest do
  use ExUnit.Case, async: true
  alias DevOrchestrator.ExecutionPolicy

  test "routine tasks use the low-cost model and narrow project capabilities" do
    policy =
      ExecutionPolicy.for_task(%{"model" => nil}, %{
        "title" => "Add a text file",
        "prompt" => "Write a short message"
      })

    assert policy["classification"] == "routine"
    assert policy["model"] == "gpt-6-luna"
    assert policy["effort"] == "low"
    assert policy["permissions"]["global_configuration"] == false
    assert policy["permissions"]["deployment"] == false
    assert policy["network"]["mode"] == "exact_host_amendments_only"
  end

  test "planning, review, fixes, and security work use the advanced model" do
    for title <- ["Plan the migration", "Review the changes", "Fix the crash", "Security audit"] do
      policy = ExecutionPolicy.for_task(%{"model" => nil}, %{"title" => title, "prompt" => ""})
      assert policy["classification"] == "advanced"
      assert policy["model"] == "gpt-6.1-sol"
      assert policy["effort"] == "high"
    end
  end

  test "unsupported deployment models are rejected instead of silently substituted" do
    refute ExecutionPolicy.valid_override?("gpt-not-deployed")
    assert ExecutionPolicy.valid_override?("gpt-6-luna")

    policy =
      ExecutionPolicy.for_task(%{"model" => "gpt-not-deployed"}, %{"title" => "Small task"})

    assert policy["valid"] == false
    assert policy["model"] == nil
    assert policy["error"] == "unsupported_model"
  end
end
