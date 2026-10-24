defmodule DevOrchestrator.ReconciliationCursorTest do
  use ExUnit.Case, async: true

  test "raw PostgreSQL timestamp cursors normalize to UTC for the next scan" do
    cursor =
      DevOrchestrator.Intake.Reconciler.cursor(%{
        "updated_at_cursor" => ~N[2026-10-23 10:00:00],
        "scan_updated_at_cursor" => ~N[2026-10-24 10:00:00],
        "page_cursor" => "next"
      })

    assert DateTime.to_iso8601(cursor.updated_at) == "2026-10-23T10:00:00Z"
    assert DateTime.to_iso8601(cursor.watermark) == "2026-10-24T10:00:00Z"
    assert cursor.page == "next"
  end
end
