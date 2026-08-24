# Run under `MIX_ENV=prod` (see test/ambient/disabled_build_test.exs), where
# config/config.exs resolves `enable_overrides` to false. Asserts the security
# property the compile-time switch exists for: no Ambient API can produce an
# override, and `Ambient.Random.bytes/1` is `:crypto.strong_rand_bytes/1` even
# if a table and a seed row are forced into existence by hand.
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

defmodule Ambient.DisabledCheckRandom do
  use Ambient.Facade, for: Ambient.Random
end

alias Ambient.ProcessOverride.Server

table = :ambient_random_overrides

Check.assert!(Ambient.ProcessOverride.enabled?() == false, "enabled?/0 should be false")

# No table exists, so reads miss.
Check.assert!(Ambient.ProcessOverride.fetch(table, :rng_state) == :error, "fetch/2 should miss")

# ── Every way a table or a row could come into being ──────────────────

Check.raises!("start_servers/1", fn -> Ambient.start_servers([Ambient.Random]) end)

Check.raises!("start_servers/1 with a bare battery", fn ->
  Ambient.start_servers(Ambient.Random)
end)

Check.raises!("Server.start_link/1", fn -> Server.start_link(table: table) end)

Check.raises!("Random.seed/1", fn -> Ambient.Random.seed(1) end)
Check.raises!("Env.put/2", fn -> Ambient.Env.put("AMBIENT_X", "1") end)
Check.raises!("Clock.set/1", fn -> Ambient.Clock.set(~U[2020-01-01 00:00:00Z]) end)
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

Check.raises!("a Facade-delegated seed/1", fn -> Ambient.DisabledCheckRandom.seed(1) end)

# Shared mode is a writer too.
Check.raises!("set_shared/2", fn -> Ambient.set_shared([Ambient.Random]) end)
Check.raises!("set_private/1", fn -> Ambient.set_private([Ambient.Random]) end)

Check.assert!(
  Ambient.ProcessOverride.mode(table) == :private,
  "mode/1 should report :private for a table that can't exist"
)

Check.assert!(:ets.whereis(table) == :undefined, "no attempt should have created the table")

# Teardown helpers stay callable – they no-op rather than raise.
Check.assert!(Ambient.Random.reset() == :ok, "Random.reset/0 should no-op")
Check.assert!(Ambient.Clock.reset() == :ok, "Clock.reset/0 should no-op")
Check.assert!(Ambient.ProcessOverride.delete(table, :rng_state) == :ok, "delete/2 should no-op")

# ── The property that makes bytes/1 credential-safe ───────────────────
#
# Forge the table and a seed row directly, bypassing every gate above. This is
# what a rogue console or dep could do, and it's why `fetch/2` alone is not the
# guarantee. `bytes/1` must still be unpredictable, because its seeded clause
# was never compiled – as must the rest of the module, which must fall through
# to `:rand` rather than crash on the write-back.

:ets.new(table, [:named_table, :public, :set])
:ets.insert(table, {{self(), :rng_state}, :rand.seed_s(:exsss, {42, 42, 42})})

Check.assert!(
  Ambient.ProcessOverride.fetch(table, :rng_state) != :error,
  "the forged row should be visible – if not, this check proves nothing"
)

Check.assert!(byte_size(Ambient.Random.bytes(32)) == 32, "bytes/1 length")

Check.assert!(
  Ambient.Random.bytes(32) != Ambient.Random.bytes(32),
  "bytes/1 must ignore a forged seed"
)

Check.assert!(Ambient.Random.uniform(10) in 1..10, "uniform/1 must fall through, not raise")
Check.assert!(length(Ambient.Random.shuffle([1, 2, 3])) == 3, "shuffle/1 must fall through")
Check.assert!(Ambient.Random.random(1..3) in 1..3, "random/1 must fall through")

Check.assert!(
  length(Ambient.Random.take_random(1..10, 3)) == 3,
  "take_random/2 must fall through"
)

Check.assert!(is_float(Ambient.Random.normal(0, 1)), "normal/2 must fall through")

# The property the README's "Production cost" table sells: `get_or/2` compiled
# the lookup away, so a battery's real read ignores even a forged row. Only
# `overridden?/1` and direct `fetch/2`/`mode/1` calls still see one.
clock_table = Ambient.Clock.__ambient_table__()
:ets.new(clock_table, [:named_table, :public, :set])
:ets.insert(clock_table, {{self(), :clock}, ~U[1999-12-31 23:59:59Z]})

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

# Battery-generated writers are gated too.
Check.raises!("a generated set_shared/1", fn -> Ambient.DisabledCheckRandom.set_shared() end)
Check.raises!("a generated set_private/0", fn -> Ambient.DisabledCheckRandom.set_private() end)
Check.raises!("a generated allow/2", fn -> Ambient.DisabledCheckRandom.allow(self()) end)

Check.raises!("get_and_update/3", fn ->
  Ambient.ProcessOverride.get_and_update(table, :k, fn s -> {s, s} end)
end)

Check.assert!(Ambient.DisabledCheckRandom.delete_all() == :ok, "delete_all/0 should no-op")

# Env's full surface.
Check.raises!("Env.unset/1", fn -> Ambient.Env.unset("AMBIENT_X") end)
Check.assert!(Ambient.Env.reset() == :ok, "Env.reset/0 should no-op")
Check.assert!(Ambient.Env.fetch("AMBIENT_NOPE") == :error, "Env.fetch/1 fall-through")

# Batteries still fall through to the real thing.
Check.assert!(match?(%DateTime{}, Ambient.Clock.utc_now()), "Clock.utc_now/0 fall-through")

System.put_env("AMBIENT_DISABLED_CHECK", "real")
Check.assert!(Ambient.Env.get("AMBIENT_DISABLED_CHECK") == "real", "Env.get/2 fall-through")
Check.assert!(Ambient.Env.get("AMBIENT_NOPE", "d") == "d", "Env.get/2 default")

IO.puts("disabled-build checks passed")
