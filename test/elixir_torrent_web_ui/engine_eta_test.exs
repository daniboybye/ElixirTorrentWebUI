defmodule ElixirTorrentWebUI.EngineETATest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.Engine

  # `left / (kbps * 1024)` has no upper bound, and `format_eta/1` prints a concrete
  # figure for whatever it gets. Reported from the UI as a day count of order 1e39
  # on a torrent whose rate had decayed to ~1e-39 KB/s.
  @max_eta_seconds 8_640_000
  @left 462_422_016

  describe "compute_eta/4" do
    test "a near-zero rate reports infinity instead of an astronomical number" do
      # The exact shape that was reported: a rate small enough that the quotient
      # overflows any sane horizon.
      assert Engine.compute_eta_for_test("Downloading", @left, 1.0e-39, 3) == :infinity
    end

    test "anything past the horizon is infinity" do
      # Chosen so left/(kbps*1024) lands just above the cap.
      kbps = @left / (@max_eta_seconds * 1024) * 0.99

      assert Engine.compute_eta_for_test("Downloading", @left, kbps, 3) == :infinity
    end

    test "a realistic slow rate still reports a real estimate" do
      # 10 KB/s on 462 MB is ~12.5 hours — slow, but a number the user can act on,
      # so it must not be swallowed by the cap.
      eta = Engine.compute_eta_for_test("Downloading", @left, 10.0, 3)

      assert is_float(eta)
      assert eta < @max_eta_seconds
      assert_in_delta eta, @left / (10.0 * 1024), 1.0
    end

    test "a fast rate is unaffected" do
      eta = Engine.compute_eta_for_test("Downloading", @left, 1000.0, 8)

      assert_in_delta eta, @left / (1000.0 * 1024), 1.0
    end

    test "the pre-existing zero, no-peer, seeding and complete cases are unchanged" do
      assert Engine.compute_eta_for_test("Downloading", @left, 0.0, 3) == :infinity
      assert Engine.compute_eta_for_test("Downloading", @left, 50.0, 0) == :infinity
      assert Engine.compute_eta_for_test("Seeding", 0, 0.0, 3) == nil
      assert Engine.compute_eta_for_test("Downloading", 0, 50.0, 3) == nil
    end
  end
end
