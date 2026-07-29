defmodule Ambient.Clock do
  @moduledoc """
  An overridable wall clock.

  In production, `utc_now/0` delegates to `DateTime.utc_now/0`. In tests, a
  per-process override set via `set/1` or `advance/1` lets time-dependent code
  (interval growth, same-day vs cross-day rollover, expiry, aging) be driven
  deterministically – without `Process.sleep` or hand-rolled date math.

  ## Inheritance

  The override lives in `Ambient.ProcessOverride`, so any child process spawned
  by the test inherits the clock through:

    * the implicit `$callers` chain (`Task`/`Agent` – no setup needed), and
    * explicit `Ambient.Clock.allow/2` for long-lived processes (GenServers,
      Oban workers).

  So `async: true` tests stay isolated, and a scenario that fans out to a
  background worker still observes the frozen test clock.

  ## Production code

      Ambient.Clock.utc_now()
      Ambient.Clock.utc_today()

  Use these instead of direct `DateTime.utc_now/0` / `Date.utc_today/0` calls
  anywhere time must be testable. A custom Credo check can enforce the
  convention project-wide.

  ## Test usage

      Ambient.Clock.set(~U[2026-01-01 09:00:00Z])
      Ambient.Clock.advance(days: 1)
      Ambient.Clock.reset()

      # For a long-lived process that must read the test clock:
      Ambient.Clock.allow(genserver_pid)
  """

  use Ambient.Value, table: :ambient_clock_overrides

  @key :clock

  @doc """
  Current UTC time. Delegates to `DateTime.utc_now/0` unless overridden – and
  in a build without overrides compiled in, *is* `DateTime.utc_now/0`, with no
  lookup at all.
  """
  @spec utc_now() :: DateTime.t()
  def utc_now do
    get_or(@key, DateTime.utc_now())
  end

  @doc """
  Today's UTC `Date`, derived from `utc_now/0` so the clock override applies.
  Use instead of `Date.utc_today/0`.
  """
  @spec utc_today() :: Date.t()
  def utc_today do
    DateTime.to_date(utc_now())
  end

  @doc """
  Current UTC time as a `NaiveDateTime`, derived from `utc_now/0`. Use instead
  of `NaiveDateTime.utc_now/0`.
  """
  @spec naive_utc_now() :: NaiveDateTime.t()
  def naive_utc_now do
    DateTime.to_naive(utc_now())
  end

  @doc """
  Current `DateTime` in the given timezone, derived from `utc_now/0`. Mirrors
  the return shape of `DateTime.now/1` (requires a configured time zone
  database) so it's a drop-in replacement.
  """
  @spec now(Calendar.time_zone()) :: {:ok, DateTime.t()} | {:error, term()}
  def now(time_zone) do
    DateTime.shift_zone(utc_now(), time_zone)
  end

  @doc "Freeze the clock at `dt` for the current process (and its children)."
  if @ambient_enabled do
    @spec set(DateTime.t()) :: DateTime.t()
  else
    @spec set(DateTime.t()) :: no_return()
  end

  def set(%DateTime{} = dt) do
    put_override(@key, dt)
    dt
  end

  @doc """
  Advance the clock and return the new time.

  Accepts a keyword list with any of `:seconds`, `:minutes`, `:hours`, `:days`
  (summed) – or a bare integer treated as seconds. Values may be negative to
  move backwards.

      Ambient.Clock.advance(days: 1)
      Ambient.Clock.advance(hours: 1, minutes: 30)   # 5400 seconds
      Ambient.Clock.advance(-90)                     # back 90 seconds
  """
  @units [seconds: 1, minutes: 60, hours: 3600, days: 86_400]

  if @ambient_enabled do
    @spec advance(integer() | keyword()) :: DateTime.t()
  else
    @spec advance(integer() | keyword()) :: no_return()
  end

  def advance(seconds) when is_integer(seconds) do
    utc_now() |> DateTime.add(seconds, :second) |> set()
  end

  def advance(opts) when is_list(opts) do
    {known, unknown} = Keyword.split(opts, Keyword.keys(@units))

    if unknown != [] do
      raise ArgumentError,
            "advance/1 got unknown unit(s) #{inspect(Keyword.keys(unknown))}; " <>
              "use :seconds, :minutes, :hours, or :days"
    end

    if known == [] do
      raise ArgumentError, "advance/1 requires :seconds, :minutes, :hours, or :days"
    end

    # Fold the caller's list, not @units: `Keyword.get/3` would see only the
    # first of a repeated unit, so `advance(hours: 1, hours: 2)` advanced one
    # hour where the docs promise the units are summed.
    known
    |> Enum.map(fn {unit, amount} -> amount * @units[unit] end)
    |> Enum.sum()
    |> advance()
  end

  @doc "Drop the override; `utc_now/0` returns to the real clock."
  @spec reset() :: :ok
  def reset do
    delete_override(@key)
  end

  @doc "Whether a clock override is currently in effect for this process."
  @spec overridden?() :: boolean()
  def overridden? do
    overridden?(@key)
  end
end
