defmodule Ambient.ProcessOverride do
  @moduledoc """
  ETS-backed process-local override store with cross-process inheritance –
  the shared engine behind `Ambient.Clock`, `Ambient.Random`, `Ambient.Env`
  and `Ambient.Config`, and behind any value module you build with
  `Ambient.Value`.

  ## Why

  Tests need to override values (config, the clock, a random seed) for the
  duration of a single test process without polluting concurrent peers. The
  naive approach, `Process.put/2`, breaks the moment work crosses a process
  boundary (`Task.async`, `GenServer.cast`, an Oban worker spawned inline).
  Both Phoenix's `ConnTest` and Ecto's SQL sandbox solve this with an explicit
  "allow" mechanism plus the `$callers` chain. This module is the equivalent
  for arbitrary key/value overrides.

  ## Lookup chain

  When the calling process reads a value, the resolver walks:

    1. **self** – `{self(), key}` in the table.
    2. **allow chain** – `{:allow, child}` → `owner`, then recurse on `owner`.
       Used when a long-lived process (a GenServer the test didn't spawn) must
       read the test's overrides.
    3. **`$callers`** – the implicit caller chain Erlang attaches to Task/Agent
       spawns. The first ancestor that owns an override wins. No code change
       needed for plain `Task.async` callers.

  ## Modes

  A table is **private** by default: each process resolves its own value
  through the chain above, which is what makes `async: true` safe.

  `set_shared/2` switches a table to **shared mode**, where one owner's
  overrides are what every process reads, however it was spawned – the
  equivalent of `Ecto.Adapters.SQL.Sandbox`'s shared mode or
  `Mox.set_mox_global/0`, and subject to the same rule: `async: false` only.
  While shared, only the owner may write (`put/3` from anyone else raises
  `{:not_shared_owner, pid}`) and `allow/3` is refused. The owner is monitored,
  so its exit returns the table to private on its own.

  The mode lives in the table as a `:mode` row rather than in the `Server`, so
  a read stays a plain ETS lookup with no message round-trip.

  ## Cleanup

  Each `Ambient.ProcessOverride.Server` instance owns one ETS table and
  monitors every PID that put a value. When a monitored PID exits, its rows
  and any `{:allow, …}` rows pointing at it are cleared. No leaks across tests.

  ## The compile-time switch

  The whole override machinery is gated on one compile-time flag:

      # config/config.exs
      config :ambient, enable_overrides: config_env() != :prod

  Always derive it from `config_env/0`. Hard-coding `true` would put the
  machinery in your release, which is the one way to defeat everything below.
  Compiling this library with the flag on under `MIX_ENV=prod` emits a warning
  for exactly that reason.

  It defaults to **`false`**. In a build that didn't opt in, no *Ambient* API
  can produce an override: `put/3` and `allow/3` raise; `Ambient.start_servers/1`,
  `Server.start_link/1` and `Server.init/1` refuse to create the ETS table; and
  `Ambient.Random`'s seeded code paths aren't compiled at all. No seeds script,
  remote console, `$callers` chain or `allow/3` grant re-opens them.

  What it is *not*: `fetch/2` keeps its ETS lookup in disabled builds (see its
  docs for why), so code that hand-rolls `:ets.new(:ambient_clock_overrides,
  [:named_table, :public])` and inserts a row *is* visible to anything reading
  through `fetch/2` directly – including `mode/1` and the built-ins'
  `overridden?/1`. It is **not** visible to the built-ins' actual reads:
  `Ambient.Value`'s `get_or/2` compiles the lookup away, so `Clock.utc_now/0`
  and a generated config `get/2` ignore such a row entirely. Forging one takes arbitrary
  code execution inside the node anyway.
  That is what makes `bytes/1` safe for credential material in production
  while staying deterministic under `Ambient.Random.seed/1` in tests.

  Two more properties worth knowing:

    * Mix records the value in the app manifest, so a release whose runtime
      config disagrees **aborts at boot** rather than drifting. (A `mix run` in
      `:prod`, unlike a release, does not perform that check.)
    * It resolves **per `_build` env**, so a release built with `MIX_ENV=test`
      would carry the machinery. Build releases with `MIX_ENV=prod`.

  Check the current build with `enabled?/0`.

  ## Dialyzer

  Gate the flag on `config_env() != :prod`, not `== :test`. In a build without
  overrides the writers raise, so their success typing is `none()` – and
  `dialyxir` runs in `:dev` by default, which is exactly the build `== :test`
  leaves without overrides. Ambient's own generated specs say `no_return()`
  there, so the library stays clean either way, but a function of *yours* that
  wraps a writer still can't return:

      def put(tenant), do: put_override(:tenant, tenant)
      # warning: Function put/1 has no local return

  Measured on a small consuming app with one `use Ambient.Config` and one
  `use Ambient.Value`: zero warnings under `!= :prod`, one under `== :test`.
  If you'd rather keep `== :test`, move such wrappers behind
  `if Ambient.ProcessOverride.enabled?()`, which compiles them out of the build
  that couldn't run them anyway.

  ## API

  All functions take the ETS table atom – each consumer module owns the naming
  so two domains can't collide. Convention: `:ambient_<domain>_overrides`.

      Ambient.ProcessOverride.put(:ambient_clock_overrides, :clock, ~U[2026-01-01 00:00:00Z])
      Ambient.ProcessOverride.fetch(:ambient_clock_overrides, :clock)
      Ambient.ProcessOverride.allow(:ambient_clock_overrides, worker_pid)
      Ambient.ProcessOverride.delete(:ambient_clock_overrides, :clock)
  """

  @type table :: atom()
  @type key :: term()
  @type value :: term()

  @enabled Application.compile_env(:ambient, :enable_overrides, false)

  # The one way a consumer defeats the switch is hard-coding it on, which puts
  # the machinery in the release and makes `Random.bytes/1` downgradeable
  # again. Warn while compiling into a prod build.
  #
  # Not `Mix.env/0`: Mix compiles dependencies with `env: :prod` by default, so
  # inside a dep it always reads `:prod`, even for a consumer's test build.
  # `MIX_ENV` is the consumer's stated intent, but it's unset when Mix picks the
  # env itself (`mix release` via `preferred_envs`) – which is precisely the
  # build that matters – so fall back to the build directory Mix actually chose.
  # Under `build_per_environment: false` that's "shared" and neither signal
  # fires; nothing better is exposed to a dep, and the docs don't promise more.
  if @enabled and
       (System.get_env("MIX_ENV") == "prod" or
          Path.basename(Mix.Project.build_path()) == "prod") do
    IO.warn(
      "Ambient was compiled into a :prod build with `enable_overrides: true`. " <>
        "That build carries the override machinery, so Ambient.Random.bytes/1 " <>
        "can be downgraded to a seeded stream by any ambient seed. Derive the " <>
        "flag from the env: `config :ambient, enable_overrides: config_env() != :prod`.",
      []
    )
  end

  @doc """
  Whether the override machinery was compiled into this build.

  `false` unless the consuming app opted the env in. When `false`, `put/3`,
  `allow/3`, `Server.start_link/1` and `Server.init/1` all refuse, so no
  Ambient API can create a table or an override – see the moduledoc for the
  one thing that is still possible, and why.

  Intended for **compile-time** branching – put it in a module body:

      if Ambient.ProcessOverride.enabled?() do
        def helper, do: :test_only
      else
        def helper, do: :real
      end

  Branching on it at *runtime* is harmless but pointless: the value is fixed
  when Ambient is compiled, so one arm is simply dead code.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: !!@enabled

  if @enabled do
    @doc """
    Store a process-local override. The `key` lets one table host multiple keys
    per owner (e.g. config). Pass a sentinel like `:clock` for
    single-value-per-owner tables.

    The current process is monitored – its rows clear automatically on exit.
    """
    @spec put(table(), key(), value()) :: :ok
    def put(table, key, value) do
      ensure_started!(table)
      ensure_writable!(table)
      # Monitor before inserting so the row can never be visible without a
      # monitor watching for the owner's exit (else a crash in the gap would
      # orphan the row until pid reuse).
      GenServer.cast(server_name(table), {:monitor, self()})
      :ets.insert(table, {{self(), key}, value})
      :ok
    end

    @doc """
    Authorise `child_pid` to inherit overrides from `owner_pid`.

    Use this for long-lived processes (GenServers, Oban workers, Tasks spawned
    outside the `$callers` chain) that need to read the test's overrides. Mirrors
    `Ecto.Adapters.SQL.Sandbox.allow/3`.
    """
    @spec allow(table(), pid(), pid()) :: :ok
    def allow(table, child_pid, owner_pid \\ self())
        when is_pid(child_pid) and is_pid(owner_pid) do
      ensure_started!(table)

      case shared_owner(table) do
        nil ->
          # Monitor *and* insert inside the Server, in one call. Doing it from
          # here would race: `child_pid` can die between the two steps, the
          # Server handles the :DOWN with no row to clean, and the row is then
          # orphaned until pid reuse hands the grant to an unrelated process.
          # A cast can't fix that – only being on the same side of the Server's
          # mailbox as the :DOWN can.
          :ok = GenServer.call(server_name(table), {:allow, child_pid, owner_pid})

        _owner ->
          raise Ambient.Error, reason: :cant_allow_in_shared_mode, table: table
      end
    end

    @doc """
    Switch `table` to **shared mode**: `owner_pid`'s overrides become the ones
    every process reads, no matter how it was spawned.

    For `async: false` tests only – it is global state, exactly like
    `Ecto.Adapters.SQL.Sandbox`'s shared mode or `Mox.set_mox_global/0`. A
    concurrent test would see the shared owner's clock.

    While shared, only `owner_pid` may write to the table (`put/3` from anyone
    else raises `{:not_shared_owner, pid}`) and `allow/3` is refused – every
    process already reads the owner's values, so there is nothing to grant.
    `get_and_update/3` is the exception, so read-modify-write modules like
    `Ambient.Random` keep working – atomically – from every process.

    Handing over to a different owner is the current owner's call: once shared,
    `set_shared/2` from anyone else raises `{:not_shared_owner, pid}` rather
    than silently stealing the table.

    The owner is monitored: if it exits, the table drops back to private mode
    on its own, so a crashed test can't leave the suite globally overridden.
    """
    @spec set_shared(table(), pid()) :: :ok
    def set_shared(table, owner_pid \\ self()) when is_pid(owner_pid) do
      ensure_started!(table)
      ensure_writable!(table)
      # Same race as allow/3, with a worse outcome: an owner that dies in the
      # gap leaves the table stuck shared to a dead pid, where every write
      # raises until someone calls set_private/1.
      :ok = GenServer.call(server_name(table), {:set_shared, owner_pid})
    end

    @doc """
    Return `table` to private (process-scoped) mode. Idempotent, and a no-op if
    the table was never shared. Existing overrides are left alone – they simply
    resolve per process again.

    Deliberately callable by *any* process, unlike the other writers: it is the
    way back to a sane state, and `ExUnit`'s `on_exit/1` runs in a different
    process from the test that took the table shared.
    """
    @spec set_private(table()) :: :ok
    def set_private(table) do
      ensure_started!(table)
      :ets.delete(table, :mode)
      :ok
    end

    @doc """
    Atomically read the value for `key`, run `fun` over it, and store the
    result. Returns `{:ok, value}` where `value` is `fun`'s first element, or
    `:error` if no override is in scope.

    For values whose reads *write*: `Ambient.Random` advances its seed state on
    every draw. A plain `fetch/2` then `put/3` is fine in private mode, where
    each process owns its own row, but in shared mode every process is reading
    and writing the *same* row – so two concurrent draws read the same state,
    compute the same number and overwrite each other. Measured before this
    existed: 99 lost updates in 200 concurrent draws, i.e. half the callers got
    a duplicate.

    In shared mode the whole read-modify-write therefore happens inside the
    `Server`, which serialises it. Private mode stays client-side, since a
    process can't race itself.

    If `fun` raises (or returns something other than a two-tuple), the
    exception surfaces in the *caller*, with the caller's stacktrace, in both
    modes. In shared mode it is caught inside the `Server` and re-raised here:
    letting it escape there would take the table owner down with it and void
    every override in the table.

    Note what this does *not* buy: which concurrent caller gets which value
    still depends on scheduling. One advancing stream and reproducible ordering
    are mutually exclusive under concurrency.
    """
    @spec get_and_update(table(), key(), (value() -> {result, value()})) :: {:ok, result} | :error
          when result: term()
    def get_and_update(table, key, fun) do
      # The existence check has to come first: `shared_owner/1` is a bare
      # `:ets.lookup`, so on an unstarted table it raised where a read should
      # simply miss. No table means no override, which means nothing to update.
      cond do
        not table_exists?(table) ->
          :error

        owner = shared_owner(table) ->
          case GenServer.call(server_name(table), {:get_and_update, owner, key, fun}) do
            # `fun` raised inside the Server. It caught it rather than dying
            # with the table; re-raise here so the caller sees its own
            # exception with its own stacktrace, exactly as in private mode.
            {:ambient_raise, kind, reason, stacktrace} ->
              :erlang.raise(kind, reason, stacktrace)

            result ->
              result
          end

        true ->
          with {:ok, current} <- fetch(table, key) do
            {value, updated} = fun.(current)
            put(table, key, updated)
            {:ok, value}
          end
      end
    end

    defp ensure_started!(table) do
      if not table_exists?(table) do
        raise Ambient.Error, reason: :server_not_started, table: table
      end
    end

    # In shared mode the shared owner is the only writer; everyone else reads
    # its values and must not be able to shadow them with rows of their own.
    defp ensure_writable!(table) do
      case shared_owner(table) do
        nil -> :ok
        owner when owner == self() -> :ok
        owner -> raise Ambient.Error, reason: {:not_shared_owner, owner}, table: table
      end
    end
  else
    @doc "Raises – overrides are not compiled into this build. See `enabled?/0`."
    @spec put(table(), key(), value()) :: no_return()
    def put(table, _key, _value), do: raise_disabled!(table)

    @doc "Raises – overrides are not compiled into this build. See `enabled?/0`."
    @spec allow(table(), pid(), pid()) :: no_return()
    def allow(table, child_pid, owner_pid \\ self())
        when is_pid(child_pid) and is_pid(owner_pid) do
      raise_disabled!(table)
    end

    @doc "Raises – overrides are not compiled into this build. See `enabled?/0`."
    @spec set_shared(table(), pid()) :: no_return()
    def set_shared(table, owner_pid \\ self()) when is_pid(owner_pid) do
      raise_disabled!(table)
    end

    @doc "Raises – overrides are not compiled into this build. See `enabled?/0`."
    @spec set_private(table()) :: no_return()
    def set_private(table), do: raise_disabled!(table)

    @doc "Raises – overrides are not compiled into this build. See `enabled?/0`."
    @spec get_and_update(table(), key(), (value() -> {term(), value()})) :: no_return()
    def get_and_update(table, _key, _fun), do: raise_disabled!(table)

    @spec raise_disabled!(table()) :: no_return()
    defp raise_disabled!(table) do
      raise Ambient.Error, reason: :overrides_disabled, table: table
    end
  end

  @doc """
  Fetch the override in effect for the calling process.

  In private mode (the default) that means the lookup chain
  self → allow → `$callers`; in shared mode it is always the shared owner's
  value, whoever asks. Returns `:error` if no override is in effect – including
  when the table doesn't exist, which is *every* build that didn't opt in,
  since nothing there can create one.

  Deliberately not compiled away in disabled builds: a clause hard-wired to
  `:error` makes every caller's `{:ok, _}` branch provably dead, and the
  compiler reports those as warnings in consuming apps. The cost of keeping it
  is a single `:ets.whereis/1`.
  """
  @spec fetch(table(), key()) :: {:ok, value()} | :error
  def fetch(table, key) do
    with true <- table_exists?(table),
         owner when not is_nil(owner) <- resolve_owner(table, key),
         [{_, value}] <- :ets.lookup(table, {owner, key}) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  @doc """
  Report whether `table` is process-scoped or globally shared.

  Returns `:private` for an unknown table, so it is safe to call anywhere.
  """
  @spec mode(table()) :: :private | {:shared, pid()}
  def mode(table) do
    with true <- table_exists?(table),
         owner when is_pid(owner) <- shared_owner(table) do
      {:shared, owner}
    else
      _ -> :private
    end
  end

  @doc """
  Remove the current process's override for `key`. No-op if absent, if the
  table doesn't exist, or if overrides aren't compiled in – teardown helpers
  stay safe to call unconditionally.
  """
  @spec delete(table(), key()) :: :ok
  def delete(table, key) do
    if table_exists?(table), do: :ets.delete(table, {self(), key})
    :ok
  end

  @doc """
  Remove every override the calling process owns in `table`. Same no-op
  guarantees as `delete/2` – safe on an unknown table or a disabled build.

  Does not touch `allow` grants or the table's mode; use `set_private/1` for
  the latter.
  """
  @spec delete_all(table()) :: :ok
  def delete_all(table) do
    if table_exists?(table), do: :ets.match_delete(table, {{self(), :_}, :_})
    :ok
  end

  # ── Owner resolution ──────────────────────────────────────────────────

  # In a build that didn't opt in, nothing can create the table, so this is
  # also the "are overrides possible at all" check. Inlined: `fetch/2` is the
  # hot path.
  @compile {:inline, table_exists?: 1}
  defp table_exists?(table), do: :ets.whereis(table) != :undefined

  # Shared mode short-circuits the whole chain: one owner for everyone. Stored
  # as a row in the table itself rather than in the Server, so a read stays a
  # plain ETS lookup with no message round-trip. `:mode` is a bare atom, so it
  # can't collide with the `{pid, key}` and `{:allow, pid}` rows – including in
  # the Server's `match_delete/2` cleanup patterns.
  defp resolve_owner(table, key) do
    case shared_owner(table) do
      nil -> find_owner(self(), table, key, [])
      owner -> owner
    end
  end

  # Callers must have established that `table` exists – this is a bare lookup
  # and raises on a missing table. `fetch/2`, `mode/1` and `get_and_update/3`
  # check first; the writers get there via `ensure_started!/1`.
  defp shared_owner(table) do
    case :ets.lookup(table, :mode) do
      [{:mode, {:shared, owner}}] -> owner
      [] -> nil
    end
  end

  # Resolve which process owns an override for *this specific key*, walking
  # self → allow chain → `$callers`. `visited` guards against a cycle in the
  # allow chain (A allows B, B allows A, or a self-allow), which would
  # otherwise spin forever. Resolution is key-aware: a table may host many
  # keys owned by different ancestors, so we must match on the key, not merely
  # "owns some key".
  # `visited` is a plain list: an allow chain is a handful of pids at most, and
  # MapSet's opaque type upsets dialyzer here for no benefit at this size.
  @spec find_owner(pid(), table(), key(), [pid()]) :: pid() | nil
  defp find_owner(pid, table, key, visited) do
    cond do
      pid in visited ->
        nil

      key_present?(table, pid, key) ->
        pid

      owner = allowed_owner(table, pid) ->
        find_owner(owner, table, key, [pid | visited])

      caller = first_caller_with_key(table, key) ->
        caller

      true ->
        nil
    end
  end

  defp key_present?(table, pid, key), do: :ets.member(table, {pid, key})

  defp allowed_owner(table, pid) do
    case :ets.lookup(table, {:allow, pid}) do
      [{_, owner}] -> owner
      [] -> nil
    end
  end

  defp first_caller_with_key(table, key) do
    Enum.find(Process.get(:"$callers", []), &key_present?(table, &1, key))
  end

  @doc """
  Compute the registered name of the `Server` instance that owns `table`.
  Public so the `Server` can register itself under the same name `put/3` calls.
  """
  @spec server_name(table()) :: atom()
  def server_name(table) when is_atom(table) do
    # The GenServer's registered name has no corresponding module – mint it
    # here. The set of tables is bounded at boot (started from test_helper),
    # so atom growth is bounded too.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    Module.concat([__MODULE__, "Server", table])
  end
end
