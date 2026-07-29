defmodule Ambient.Config do
  @moduledoc """
  An app-config accessor with a per-process override layer for test isolation.

  `use` it once to bind it to your OTP application:

      defmodule MyApp.Config do
        use Ambient.Config, otp_app: :my_app
      end

  This generates the domain API – `get/2`, `put/2`, `revert/1`, `reset/0` –
  where `get/2` reads a per-process override first (via
  `Ambient.ProcessOverride`), then falls back to
  `Application.get_env(:my_app, key, default)`.

  Underneath, `Ambient.Value` supplies the generic layer those wrap
  (`put_override/2`, `delete_override/1`, `delete_all/0`) plus `overridden?/1`,
  `allow/2`, `set_shared/1` and `set_private/0`. You can `use Ambient.Value`
  directly to build overridable values of your own.

  ## Why not `Application.put_env/3` in tests?

  `Application.put_env/3` is global – concurrent `async: true` tests clobber
  each other. `put/2` is process-local, inherited by spawned children
  (`$callers` + `allow/2`), and auto-cleaned on exit. Safe under `async: true`.

  ## Usage

      # production / app code
      MyApp.Config.get(:feature_x_enabled, false)

      # tests
      MyApp.Config.put(:feature_x_enabled, true)
      MyApp.Config.revert(:feature_x_enabled)
      MyApp.Config.reset()

      # for a GenServer that reads config in its own process:
      MyApp.Config.allow(genserver_pid)

  Remember to start the override server for the generated table in
  `test/test_helper.exs`:

      Ambient.start_servers([MyApp.Config])
  """

  @doc false
  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    table = :"ambient_config_overrides_#{otp_app}"

    writes =
      if Ambient.ProcessOverride.enabled?(), do: quote(do: :ok), else: quote(do: no_return())

    quote do
      use Ambient.Value, table: unquote(table)

      @ambient_otp_app unquote(otp_app)

      @doc """
      Read a config value. Checks for a process-local override first, then
      falls back to `Application.get_env(#{inspect(unquote(otp_app))}, key, default)`.

      In a build without overrides compiled in, the lookup disappears and this
      *is* `Application.get_env/3`.
      """
      @spec get(atom()) :: term()
      @spec get(atom(), term()) :: term()
      def get(key, default \\ nil) do
        get_or(key, Application.get_env(@ambient_otp_app, key, default))
      end

      @doc """
      Override `key` for this process and everything it spawns (test only).
      The application environment is untouched.
      """
      @spec put(atom(), term()) :: unquote(writes)
      def put(key, value), do: put_override(key, value)

      @doc """
      Drop this process's override for `key`, so `get/2` resolves normally
      again – an ancestor's override if there is one, otherwise app env.
      """
      @spec revert(atom()) :: :ok
      def revert(key), do: delete_override(key)

      @doc "Drop every override this process set in this config table."
      @spec reset() :: :ok
      def reset, do: delete_all()

      defoverridable get: 1, get: 2, put: 2, revert: 1, reset: 0
    end
  end
end
