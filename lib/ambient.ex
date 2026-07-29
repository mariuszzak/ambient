defmodule Ambient do
  @moduledoc """
  Ambient – process-scoped value overrides for Elixir, with built-ins.

  An *ambient value* is one resolved implicitly from the surrounding context
  rather than threaded through arguments. `Ambient` lets a test set such a
  value (the current time, a random seed, a config entry) scoped to its process
  **and everything that process spawns**, with zero leakage across concurrent
  `async: true` tests and automatic cleanup on exit.

  ## Built-in values

    * `Ambient.Clock`  – an overridable wall clock (freeze / travel time)
    * `Ambient.Random` – a seedable, replayable random number generator
    * `Ambient.Env`    – overridable OS environment variables
    * `Ambient.Config` – an app-config accessor with a per-process override layer

  All four sit on `Ambient.ProcessOverride`, the shared engine (ETS +
  `$callers` inheritance + an Ecto-Sandbox-style `allow/3`), and are assembled
  with `Ambient.Value` – which you can `use` to build overridable values of
  your own.

  ## Reaching other processes

  `Task`/`Agent` children inherit through `$callers` with no setup. For a
  long-lived process the test didn't spawn, grant it explicitly with the
  module's `allow/2`. When you can't reach the process at all, `set_shared/2`
  makes one process's overrides global for the duration of an `async: false`
  test.

  ## Setup

  Opt the test build into the override machinery – it is off by default:

      # config/config.exs
      config :ambient, enable_overrides: config_env() != :prod

  Then start one override server per table before the suite runs, in
  `test/test_helper.exs`:

      Ambient.start_servers([Ambient.Clock, Ambient.Random, Ambient.Env, MyApp.Config])
      ExUnit.start()

  In production the flag is `false` and the override branches aren't compiled
  at all: each wrapper *is* the function it wraps – `DateTime.utc_now/0`,
  `:rand.uniform/1`, `:crypto.strong_rand_bytes/1`, `System.get_env/2`,
  `Application.get_env/3` – with no lookup and no branch. See
  `Ambient.ProcessOverride` for what that guarantees.
  """

  alias Ambient.ProcessOverride
  alias Ambient.ProcessOverride.Server

  @typedoc """
  One value module or a list of them: a module that `use`s `Ambient.Value`
  (including a `use Ambient.Facade` wrapper of one), or a raw table atom.
  """
  @type values :: module() | atom() | [module() | atom()]

  @doc """
  Start one override `Server` per given table.

  Accepts one value module or a list of them: `Ambient.Clock`,
  `Ambient.Random`, a module that `use`s `Ambient.Config` or `Ambient.Value`, a
  `use Ambient.Facade` wrapper of one – anything exporting `__ambient_table__/0` –
  or raw table atoms. Idempotent: a table whose server is already running is
  skipped.

  Call once from `test/test_helper.exs` before `ExUnit.start/0`.

  Raises unless the build opted into overrides
  (`config :ambient, enable_overrides: config_env() != :prod`) – see
  `Ambient.ProcessOverride`. Failing here means a consumer who forgot the
  config line fails loudly at suite boot instead of watching every override
  silently fall through to real values.
  """
  @spec start_servers(values()) :: :ok
  def start_servers(values) do
    ensure_enabled!()
    ensure_supervisor!()
    Enum.each(normalize!(values), &start_one(table_for(&1)))
  end

  @doc """
  Switch the given tables to **shared mode**, with `owner_pid` as the process
  whose overrides everyone reads.

  Accepts the same modules as `start_servers/1`, singly or as a list.

      test "the whole system sees the frozen clock" do
        Ambient.Clock.set(~U[2026-01-01 09:00:00Z])
        Ambient.set_shared(Ambient.Clock)
        on_exit(fn -> Ambient.set_private(Ambient.Clock) end)
        # … any process, however spawned, now reads that clock
      end

  This is global state, so use it only in `async: false` tests – the same rule
  as `Ecto.Adapters.SQL.Sandbox`'s shared mode and `Mox.set_mox_global/0`. The
  owner is monitored, so a crashed test reverts the table on its own.

  See `Ambient.ProcessOverride.set_shared/2` for the per-table details.
  """
  @spec set_shared(values(), pid()) :: :ok
  def set_shared(values, owner_pid \\ self()) when is_pid(owner_pid) do
    Enum.each(normalize!(values), &ProcessOverride.set_shared(table_for(&1), owner_pid))
  end

  @doc """
  Return the given modules to private (process-scoped) mode. Idempotent, and
  safe to call on tables that were never shared. Callable from any process –
  `on_exit/1` runs in its own.
  """
  @spec set_private(values()) :: :ok
  def set_private(values) do
    Enum.each(normalize!(values), &ProcessOverride.set_private(table_for(&1)))
  end

  # Resolved at compile time, like `Ambient.ProcessOverride`'s own gate – a
  # runtime `if enabled?()` would be dead code the type checker (rightly)
  # flags as constant.
  if Application.compile_env(:ambient, :enable_overrides, false) do
    defp ensure_enabled!, do: :ok
  else
    defp ensure_enabled! do
      raise Ambient.Error, reason: :overrides_disabled
    end
  end

  defp ensure_supervisor! do
    case Ambient.Supervisor.start_link() do
      # Unlink: whoever calls start_servers/1 first owns the link otherwise –
      # usually test_helper.exs's process, but a consumer calling it from a
      # `setup` block would tie the supervisor's fate to one test's.
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp table_for(mod) when is_atom(mod) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, :__ambient_table__, 0) ->
        mod.__ambient_table__()

      # A module-looking atom that isn't a valid value module is almost certainly a
      # typo (`Ambient.Cock`) or the wrong module – fail loud rather than
      # silently registering a bogus table.
      module_atom?(mod) ->
        raise Ambient.Error, reason: :not_a_value_module, table: mod

      true ->
        mod
    end
  end

  defp module_atom?(atom), do: match?("Elixir." <> _, Atom.to_string(atom))

  # Accept a single value module as well as a list, so `Ambient.set_shared(MyApp.Clock)`
  # reads the way people write it and `Ambient.ProcessOverride`'s same-named
  # functions can't be confused for these by argument shape.
  defp normalize!(values) when is_list(values), do: values
  defp normalize!(value) when is_atom(value) and not is_nil(value), do: [value]

  defp normalize!(other) do
    raise Ambient.Error, reason: :not_a_value_module, table: other
  end

  defp start_one(table) do
    spec = %{
      id: table,
      start: {Server, :start_link, [[table: table]]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(Ambient.Supervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise Ambient.Error, reason: {:server_start_failed, reason}, table: table
    end
  end
end
