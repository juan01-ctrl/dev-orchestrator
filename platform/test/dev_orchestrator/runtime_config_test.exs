defmodule DevOrchestrator.RuntimeConfigTest do
  use ExUnit.Case, async: true

  test "public origin rejects insecure URLs, paths and embedded credentials" do
    assert DevOrchestrator.RuntimeConfig.public_origin!("https://control.example") ==
             "https://control.example"

    for url <- [
          "http://control.example",
          "https://user:password@control.example",
          "https://control.example/nested",
          "https://control.example?token=private"
        ] do
      assert_raise ArgumentError, fn -> DevOrchestrator.RuntimeConfig.public_origin!(url) end
    end
  end
end
