defmodule Ambient.ClockTest do
  use ExUnit.Case, async: true

  alias Ambient.Clock

  @t ~U[2026-01-01 09:00:00Z]

  describe "production (no override)" do
    test "utc_now is close to the real clock" do
      diff = DateTime.diff(DateTime.utc_now(), Clock.utc_now(), :second) |> abs()
      assert diff <= 2
      refute Clock.overridden?()
    end
  end

  describe "override" do
    test "set/1 freezes the clock and reports overridden?" do
      assert Clock.set(@t) == @t
      assert Clock.utc_now() == @t
      assert Clock.overridden?()
    end

    test "utc_today / naive_utc_now / now derive from the override" do
      Clock.set(@t)
      assert Clock.utc_today() == ~D[2026-01-01]
      assert Clock.naive_utc_now() == ~N[2026-01-01 09:00:00]
      assert {:ok, %DateTime{}} = Clock.now("Etc/UTC")
    end

    test "advance/1 supports units and bare seconds" do
      Clock.set(@t)
      assert Clock.advance(days: 1) == ~U[2026-01-02 09:00:00Z]
      Clock.set(@t)
      assert Clock.advance(hours: 2) == ~U[2026-01-01 11:00:00Z]
      Clock.set(@t)
      assert Clock.advance(minutes: 30) == ~U[2026-01-01 09:30:00Z]
      Clock.set(@t)
      assert Clock.advance(90) == ~U[2026-01-01 09:01:30Z]
    end

    test "advance/1 sums multiple units" do
      Clock.set(@t)
      assert Clock.advance(hours: 1, minutes: 30) == ~U[2026-01-01 10:30:00Z]
    end

    test "advance/1 moves backwards with negative amounts" do
      Clock.set(@t)
      assert Clock.advance(-3600) == ~U[2026-01-01 08:00:00Z]
      Clock.set(@t)
      assert Clock.advance(days: -1) == ~U[2025-12-31 09:00:00Z]
    end

    test "advance is reflected in utc_today and naive_utc_now" do
      Clock.set(@t)
      Clock.advance(days: 1)
      assert Clock.utc_today() == ~D[2026-01-02]
      assert Clock.naive_utc_now() == ~N[2026-01-02 09:00:00]
    end

    test "advance/1 raises on an unknown unit" do
      Clock.set(@t)
      assert_raise ArgumentError, fn -> Clock.advance(weeks: 1) end
    end

    test "advance/1 raises on a typo'd unit mixed with a known one" do
      Clock.set(@t)
      # `hour` (should be `hours`) must surface, not be silently dropped
      assert_raise ArgumentError, fn -> Clock.advance(days: 1, hour: 2) end
    end

    test "reset/0 restores the real clock" do
      Clock.set(@t)
      assert Clock.overridden?()
      assert :ok = Clock.reset()
      refute Clock.overridden?()
    end
  end

  describe "inheritance" do
    test "a Task inherits the frozen clock" do
      Clock.set(@t)
      assert Task.async(fn -> Clock.utc_now() end) |> Task.await() == @t
    end

    test "allow/2 shares the clock with an unrelated process" do
      Clock.set(@t)
      parent = self()

      pid =
        spawn(fn ->
          receive do
            :go -> send(parent, {:now, Clock.utc_now()})
          end
        end)

      Clock.allow(pid)
      send(pid, :go)
      assert_receive {:now, got}
      assert got == @t
    end
  end

  describe "advance/1 unit arithmetic" do
    test "sums repeated units, as the docs promise" do
      # Regression: the fold walked @units and looked each one up with
      # Keyword.get/3, which sees only the first of a repeated key – so this
      # advanced one hour, not three.
      Clock.set(~U[2026-01-01 00:00:00Z])
      assert Clock.advance(hours: 1, hours: 2) == ~U[2026-01-01 03:00:00Z]
    end

    test "sums across different units" do
      Clock.set(~U[2026-01-01 00:00:00Z])
      assert Clock.advance(hours: 1, minutes: 30) == ~U[2026-01-01 01:30:00Z]
    end

    test "negative amounts subtract" do
      Clock.set(~U[2026-01-01 12:00:00Z])
      assert Clock.advance(hours: -2, minutes: 30) == ~U[2026-01-01 10:30:00Z]
    end
  end
end
