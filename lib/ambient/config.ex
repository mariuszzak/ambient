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

  ## Nested config

  Most real config isn't flat – `config :my_app, :oauth, client_id: "…"` reads
  back as a keyword list, and the call site is `Application.get_env(:my_app,
  :oauth)[:client_id]`. Pass a path and both the read and the override target
  the leaf:

      MyApp.Config.get([:oauth, :client_id], "default")
      MyApp.Config.put([:oauth, :client_id], "test-client")

  Paths step through keyword lists and maps. A missing key anywhere along the
  way yields the default, exactly as `Application.get_env/3` does for a missing
  top-level key.

  Overrides resolve **longest prefix first**: an override on `[:oauth,
  :client_id]` wins, then one on `:oauth` (dug into), then app env. So pinning
  a whole group still works, and a group override is visible to leaf reads:

      MyApp.Config.put(:oauth, client_id: "a", secret: "b")
      MyApp.Config.get([:oauth, :client_id])   #=> "a"

  It does not work in reverse – overriding a leaf doesn't synthesize a parent,
  so `get(:oauth)` after `put([:oauth, :client_id], …)` returns the unmodified
  app-env group. Override at the level you read at.

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

  @typedoc """
  A config key: an atom for a top-level entry, or a path into a nested one.

  A single-element path is the same key as the bare atom, so `[:port]` and
  `:port` are interchangeable everywhere.
  """
  @type key :: atom() | [atom(), ...]

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
      @spec get(Ambient.Config.key()) :: term()
      @spec get(Ambient.Config.key(), term()) :: term()
      def get(key, default \\ nil)

      # Raises, rather than falling through to a deprecated
      # `Application.get_env(app, [], default)`.
      def get([], _default), do: Ambient.Config.__normalize__([])

      def get([_ | _] = path, default) do
        case Ambient.Config.__normalize__(path) do
          key when is_atom(key) -> get(key, default)
          [head | rest] -> ambient_get_path(head, rest, default)
        end
      end

      def get(key, default) do
        get_or(key, Application.get_env(@ambient_otp_app, key, default))
      end

      if @ambient_enabled do
        # Longest-prefix resolution: an override on the exact path wins, then
        # one on each shorter prefix, then app env. That is what keeps a
        # wholesale `put(:oauth, …)` visible to a `get([:oauth, :client])`
        # read – otherwise adding nesting would break every existing override.
        defp ambient_get_path(head, rest, default) do
          case Ambient.Config.__resolve__(@ambient_table, head, rest) do
            {:ok, value, remaining} -> Ambient.Config.__dig__(value, remaining, default)
            :error -> ambient_app_env_path(head, rest, default)
          end
        end
      else
        defp ambient_get_path(head, rest, default) do
          ambient_app_env_path(head, rest, default)
        end
      end

      defp ambient_app_env_path(head, rest, default) do
        case Application.fetch_env(@ambient_otp_app, head) do
          {:ok, value} -> Ambient.Config.__dig__(value, rest, default)
          :error -> default
        end
      end

      @doc """
      Override `key` for this process and everything it spawns (test only).
      The application environment is untouched.
      """
      @spec put(Ambient.Config.key(), term()) :: unquote(writes)
      def put(key, value), do: put_override(Ambient.Config.__normalize__(key), value)

      @doc """
      Drop this process's override for `key`, so `get/2` resolves normally
      again – an ancestor's override if there is one, otherwise app env.
      """
      @spec revert(Ambient.Config.key()) :: :ok
      def revert(key), do: delete_override(Ambient.Config.__normalize__(key))

      @doc "Drop every override this process set in this config table."
      @spec reset() :: :ok
      def reset, do: delete_all()

      @doc """
      Whether an override is in scope for `key`.

      Asks about that exact key: an override on a parent group does not make a
      leaf path `overridden?/1`, even though `get/2` resolves through it.
      """
      @spec overridden?(Ambient.Config.key()) :: boolean()
      def overridden?(key) do
        match?(
          {:ok, _},
          Ambient.ProcessOverride.fetch(@ambient_table, Ambient.Config.__normalize__(key))
        )
      end

      defoverridable get: 1, get: 2, put: 2, revert: 1, reset: 0, overridden?: 1
    end
  end

  @doc false
  # Takes `[atom()]` rather than `key()`: an empty path is a caller error, and
  # this is where it's rejected, so the argument type has to admit it.
  @spec __normalize__(atom() | [atom()]) :: atom() | [atom(), ...]
  def __normalize__([key]), do: key
  def __normalize__([_ | _] = path), do: path

  def __normalize__([]) do
    raise ArgumentError, "a config path must name at least one key, got: []"
  end

  def __normalize__(key), do: key

  @doc false
  @spec __resolve__(atom(), atom(), [atom()]) :: {:ok, term(), [atom()]} | :error
  def __resolve__(table, head, rest) do
    path = [head | rest]

    Enum.reduce_while(length(path)..1//-1, :error, fn taken, acc ->
      case Ambient.ProcessOverride.fetch(table, __normalize__(Enum.take(path, taken))) do
        {:ok, value} -> {:halt, {:ok, value, Enum.drop(path, taken)}}
        :error -> {:cont, acc}
      end
    end)
  end

  @doc false
  @spec __dig__(term(), [atom()], term()) :: term()
  def __dig__(value, [], _default), do: value

  def __dig__(value, [key | rest], default) do
    case __step__(value, key) do
      {:ok, next} -> __dig__(next, rest, default)
      :error -> default
    end
  end

  # Config groups are keyword lists by convention and maps often enough in
  # practice. Anything else can't be stepped into, so the read takes `default`
  # rather than raising – the same shape `Application.get_env/3` has for a
  # missing key.
  defp __step__(value, key) when is_map(value), do: Map.fetch(value, key)

  defp __step__(value, key) when is_list(value) do
    if Keyword.keyword?(value), do: Keyword.fetch(value, key), else: :error
  end

  defp __step__(_value, _key), do: :error
end
