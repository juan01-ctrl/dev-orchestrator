defmodule DevOrchestratorWeb.AssetsTest do
  use ExUnit.Case, async: true

  alias DevOrchestratorWeb.Endpoint

  test "serves the generic project instructions template" do
    conn = Plug.Test.conn(:get, "/templates/instructions.md")
    conn = Endpoint.call(conn, Endpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "# Project instructions"
    assert conn.resp_body =~ "## Project context"
    assert conn.resp_body =~ "## Repository guidance"
    assert conn.resp_body =~ "## Implementation"
    assert conn.resp_body =~ "## Validation"
    assert conn.resp_body =~ "## Git and delivery"
    assert conn.resp_body =~ "## Completion report"
    refute conn.resp_body =~ "Symphony"
    refute conn.resp_body =~ "OpenAI"
    refute conn.resp_body =~ "WORKFLOW.md"
  end
end
