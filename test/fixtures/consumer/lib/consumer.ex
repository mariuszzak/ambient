defmodule Consumer.Config do
  use Ambient.Config, otp_app: :consumer
end

defmodule Consumer.Clock do
  use Ambient.Facade, for: Ambient.Clock
end

defmodule Consumer.Flags do
  # Mirrors the README's "Build your own" example. The real one falls back to a
  # flag SDK; here the fallback is a local function, so the fixture pulls no dep
  # while keeping the same shape (fallback = the production implementation).
  use Ambient.Value, table: :consumer_flag_overrides

  def enabled?(flag, actor \\ nil), do: get_or({:flag, flag}, remote_lookup(flag, actor))

  def enable(flag), do: put_override({:flag, flag}, true)
  def disable(flag), do: put_override({:flag, flag}, false)

  defp remote_lookup(_flag, _actor), do: false
end

defmodule Consumer.TickingClock do
  # Mirrors the README's "When your reads also write" example, so a snippet that
  # doesn't compile - or that warns in a consumer's disabled build - can't ship.
  use Ambient.Value, table: :consumer_ticking_clock_overrides

  def set(%DateTime{} = dt), do: put_override(:clock, dt)

  if @ambient_enabled do
    def utc_now do
      tick = &{&1, DateTime.add(&1, 1, :millisecond)}

      case Ambient.ProcessOverride.get_and_update(@ambient_table, :clock, tick) do
        {:ok, dt} -> dt
        :error -> DateTime.utc_now()
      end
    end
  else
    def utc_now, do: DateTime.utc_now()
  end
end

defmodule Consumer do
  @moduledoc """
  Touches every part of Ambient's public surface a real app would, so that
  compiling this project with `--warnings-as-errors` proves the disabled build
  stays warning-free in *consumer* code – not just in Ambient's own.
  """

  def now, do: Consumer.Clock.utc_now()

  def timeout, do: Consumer.Config.get(:timeout, 5_000)

  def oauth_client_id, do: Consumer.Config.get([:oauth, :client_id], "none")

  def fetch_timeout, do: Consumer.Config.fetch(:timeout)
  def fetch_client_id, do: Consumer.Config.fetch([:oauth, :client_id])
  def timeout!, do: Consumer.Config.fetch!(:timeout)

  def ticked_now, do: Consumer.TickingClock.utc_now()

  def flag_on?, do: Consumer.Flags.enabled?(:new_pricing)

  # The generated domain verbs, so a disabled build compiles them in consumer
  # code too.
  def override_timeout(ms), do: Consumer.Config.put(:timeout, ms)
  def clear_timeout, do: Consumer.Config.revert(:timeout)
  def override_client_id(id), do: Consumer.Config.put([:oauth, :client_id], id)

  # The pattern that would break if `fetch/2` were compiled down to a constant
  # `:error` in disabled builds: this `{:ok, _}` clause would be unreachable.
  def raw_override do
    case Ambient.ProcessOverride.fetch(:ambient_clock_overrides, :clock) do
      {:ok, value} -> value
      :error -> :none
    end
  end
end
