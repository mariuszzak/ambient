defmodule Consumer.Config do
  use Ambient.Config, otp_app: :consumer
end

defmodule Consumer.Clock do
  use Ambient.Facade, for: Ambient.Clock
end

defmodule Consumer.Tenant do
  use Ambient.Value, table: :consumer_tenant_overrides

  def current, do: get_or(:tenant, :public)
  def put(tenant), do: put_override(:tenant, tenant)
end

defmodule Consumer do
  @moduledoc """
  Touches every part of Ambient's public surface a real app would, so that
  compiling this project with `--warnings-as-errors` proves the disabled build
  stays warning-free in *consumer* code – not just in Ambient's own.
  """

  def token, do: Ambient.Random.bytes(32) |> Base.url_encode64(padding: false)

  def jittered_backoff(base), do: base + Ambient.Random.uniform(base)

  def now, do: Consumer.Clock.utc_now()

  def timeout, do: Consumer.Config.get(:timeout, 5_000)

  def tenant, do: Consumer.Tenant.current()

  # The generated domain verbs, so a disabled build compiles them in consumer
  # code too.
  def override_timeout(ms), do: Consumer.Config.put(:timeout, ms)
  def clear_timeout, do: Consumer.Config.revert(:timeout)

  # The pattern that would break if `fetch/2` were compiled down to a constant
  # `:error` in disabled builds: this `{:ok, _}` clause would be unreachable.
  def raw_override do
    case Ambient.ProcessOverride.fetch(:ambient_clock_overrides, :clock) do
      {:ok, value} -> value
      :error -> :none
    end
  end
end
