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

  test "serves the clipboard interaction used by executor command buttons" do
    conn = Plug.Test.conn(:get, "/assets/app.js")
    conn = Endpoint.call(conn, Endpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "navigator.clipboard.writeText"
    assert conn.resp_body =~ "Copy failed"
  end

  test "serves the activity stream auto-follow hook and bounded scroll styles" do
    js = Endpoint.call(Plug.Test.conn(:get, "/assets/app.js"), Endpoint.init([]))
    css = Endpoint.call(Plug.Test.conn(:get, "/assets/app.css"), Endpoint.init([]))

    assert js.status == 200
    assert js.resp_body =~ "ActivityStream"
    assert js.resp_body =~ "scrollToLatest"
    assert css.status == 200
    assert css.resp_body =~ ".activity-stream{max-height:26rem;overflow-y:auto"
  end
end
