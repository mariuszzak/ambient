# Run under `MIX_ENV=prod` (see test/ambient/disabled_build_test.exs), where
# config/config.exs resolves `enable_overrides` to false. Asserts what the
# compile-time switch exists for: no Ambient API can produce an override, and
# a real read ignores one even if a table and a row are forced into existence
# by hand – because `get_or/2` compiled the lookup away entirely.
#
# Plain functions rather than ExUnit – ExUnit isn't loaded in :prod.

defmodule Check do
  def assert!(true, _), do: :ok
  def assert!(_, what), do: raise("disabled-build check failed: #{what}")

  # Rescues every exception class, then asserts it was the structured error we
  # meant – so a regression that swaps the guard for some other failure can't
  # slip through as a pass.
  def raises!(what, fun) do
    fun.()
    raise("disabled-build check failed: #{what} did not raise")
  rescue
    e in Ambient.Error ->
      assert!(
        e.reason == :overrides_disabled,
        "#{what} raised the wrong reason: #{inspect(e.reason)}"
      )

    e ->
      IO.puts(
        :stderr,
        "disabled-build check failed: #{what} raised #{inspect(e.__struct__)}, want Ambient.Error"
      )

      reraise(e, __STACKTRACE__)
  end
end

defmodule Ambient.DisabledCheckConfig do
  use Ambient.Config, otp_app: :ambient
end

defmodule Ambient.DisabledCheckClock do
  use Ambient.Facade, for: Ambient.Clock
end

alias Ambient.ProcessOverride.Server

table = Ambient.Clock.__ambient_table__()

Check.assert!(Ambient.ProcessOverride.enabled?() == false, "enabled?/0 should be false")

# No table exists, so reads miss.
Check.assert!(Ambient.ProcessOverride.fetch(table, :clock) == :error, "fetch/2 should miss")

# ── Every way a table or a row could come into being ──────────────────

Check.raises!("start_servers/1", fn -> Ambient.start_servers([Ambient.Clock]) end)

Check.raises!("start_servers/1 with a bare value module", fn ->
  Ambient.start_servers(Ambient.Clock)
end)

Check.raises!("Server.start_link/1", fn -> Server.start_link(table: table) end)

Check.raises!("Clock.set/1", fn -> Ambient.Clock.set(~U[2020-01-01 00:00:00Z]) end)
Check.raises!("Clock.advance/1", fn -> Ambient.Clock.advance(days: 1) end)
Check.raises!("ProcessOverride.put/3", fn -> Ambient.ProcessOverride.put(table, :k, :v) end)

Check.raises!("ProcessOverride.allow/3", fn ->
  Ambient.ProcessOverride.allow(table, self(), self())
end)

# `use GenServer` exports init/1, so gating only start_link/1 would leave this
# door open (it did, once).
Check.assert!(
  match?({:stop, %Ambient.Error{reason: :overrides_disabled}}, Server.init(table)),
  "Server.init/1 should refuse"
)

Process.flag(:trap_exit, true)

Check.assert!(
  match?({:error, %Ambient.Error{}}, GenServer.start_link(Server, table)),
  "GenServer.start_link/2 on the Server should refuse"
)

# The supervisor route `Ambient.start_servers/1` would have taken.
{:ok, sup} = Ambient.Supervisor.start_link()

Check.assert!(
  match?(
    {:error, _},
    DynamicSupervisor.start_child(sup, %{
      id: table,
      start: {Server, :start_link, [[table: table]]}
    })
  ),
  "DynamicSupervisor.start_child via Server.start_link/1 should fail"
)

Check.assert!(
  match?(
    {:error, _},
    DynamicSupervisor.start_child(sup, %{
      id: table,
      start: {GenServer, :start_link, [Server, table]}
    })
  ),
  "DynamicSupervisor.start_child via GenServer.start_link/2 should fail"
)

# The writers `use Ambient.Config` generates, and a Facade re-export.
Check.raises!("a generated Config put_override/2", fn ->
  Ambient.DisabledCheckConfig.put_override(:k, :v)
end)

Check.raises!("a generated Config put/2", fn -> Ambient.DisabledCheckConfig.put(:k, :v) end)

Check.assert!(
  Ambient.DisabledCheckConfig.revert(:k) == :ok and Ambient.DisabledCheckConfig.reset() == :ok,
  "Config revert/1 and reset/0 should no-op"
)

Check.raises!("a Facade-delegated set/1", fn ->
  Ambient.DisabledCheckClock.set(~U[2020-01-01 00:00:00Z])
end)

# Shared mode is a writer too.
Check.raises!("set_shared/2", fn -> Ambient.set_shared([Ambient.Clock]) end)
Check.raises!("set_private/1", fn -> Ambient.set_private([Ambient.Clock]) end)

Check.assert!(
  Ambient.ProcessOverride.mode(table) == :private,
  "mode/1 should report :private for a table that can't exist"
)

Check.assert!(:ets.whereis(table) == :undefined, "no attempt should have created the table")

# Teardown helpers stay callable – they no-op rather than raise.
Check.assert!(Ambient.Clock.reset() == :ok, "Clock.reset/0 should no-op")
Check.assert!(Ambient.ProcessOverride.delete(table, :clock) == :ok, "delete/2 should no-op")

# ── What the switch actually guarantees ───────────────────────────────
#
# Forge the table and a row directly, bypassing every gate above. This is what
# a rogue console or dep could do, and it's why `fetch/2` alone is not the
# guarantee: `get_or/2` compiled the lookup away, so a real read ignores even a
# forged row. Only `overridden?/1` and direct `fetch/2`/`mode/1` calls see one.
:ets.new(table, [:named_table, :public, :set])
:ets.insert(table, {{self(), :clock}, ~U[1999-12-31 23:59:59Z]})

Check.assert!(
  Ambient.ProcessOverride.fetch(table, :clock) != :error,
  "the forged row should be visible – if not, this check proves nothing"
)

Check.assert!(
  Ambient.Clock.utc_now().year != 1999,
  "Clock.utc_now/0 must ignore a forged row – get_or/2 should have compiled the lookup out"
)

Check.assert!(
  Ambient.DisabledCheckConfig.get(:anything, :real) == :real,
  "a generated Config get/2 must ignore the override layer entirely"
)

Check.assert!(
  Ambient.Clock.overridden?() == true,
  "overridden?/1 does still read ETS – if this changes, update the docs that say so"
)

# Nested reads take a different code path from flat ones, so they need their
# own gate: the disabled build must resolve them straight out of app env, and
# ignore a forged row at the exact path.
Application.put_env(:ambient, :disabled_check_group, client_id: "from-app")

Check.assert!(
  Ambient.DisabledCheckConfig.get([:disabled_check_group, :client_id]) == "from-app",
  "a nested get/2 must still read app env"
)

Check.assert!(
  Ambient.DisabledCheckConfig.get([:disabled_check_group, :missing], :real) == :real,
  "a nested get/2 must still return the default for a missing leaf"
)

config_table = Ambient.DisabledCheckConfig.__ambient_table__()
:ets.new(config_table, [:named_table, :public, :set])
:ets.insert(config_table, {{self(), [:disabled_check_group, :client_id]}, "forged"})

Check.assert!(
  Ambient.DisabledCheckConfig.get([:disabled_check_group, :client_id]) == "from-app",
  "a nested get/2 must ignore a forged row – the path lookup should be compiled out"
)

# fetch/1 has its own compiled-out split, flat and nested.
Check.assert!(
  Ambient.DisabledCheckConfig.fetch([:disabled_check_group, :client_id]) == {:ok, "from-app"},
  "a nested fetch/1 must ignore a forged row"
)

Check.assert!(
  Ambient.DisabledCheckConfig.fetch(:definitely_unset) == :error,
  "fetch/1 must miss for an absent key"
)

# The generated writers are gated too.
Check.raises!("a generated set_shared/1", fn -> Ambient.DisabledCheckClock.set_shared() end)
Check.raises!("a generated set_private/0", fn -> Ambient.DisabledCheckClock.set_private() end)
Check.raises!("a generated allow/2", fn -> Ambient.DisabledCheckClock.allow(self()) end)

Check.raises!("get_and_update/3", fn ->
  Ambient.ProcessOverride.get_and_update(table, :k, fn s -> {s, s} end)
end)

Check.assert!(Ambient.DisabledCheckClock.delete_all() == :ok, "delete_all/0 should no-op")

# The values still fall through to the real thing.
Check.assert!(match?(%DateTime{}, Ambient.Clock.utc_now()), "Clock.utc_now/0 fall-through")
Check.assert!(match?(%Date{}, Ambient.Clock.utc_today()), "Clock.utc_today/0 fall-through")

Application.put_env(:ambient, :disabled_check_flat, "real")

Check.assert!(
  Ambient.DisabledCheckConfig.get(:disabled_check_flat) == "real",
  "a generated Config get/2 fall-through"
)

IO.puts("disabled-build checks passed")
