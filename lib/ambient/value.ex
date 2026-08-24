defmodule Ambient.Value do
  @moduledoc """
  Build your own overridable value on top of `Ambient.ProcessOverride`.

  An *ambient value* is one resolved implicitly from the surrounding context
  rather than threaded through arguments. `Ambient.Config` and `Ambient.Clock`
  are both built on this module – nothing about them is privileged. If your app
  has an ambient value of its own (the current tenant, the acting user, a
  request id), this is the supported way to make it as testable as they are.

      defmodule MyApp.Tenant do
        use Ambient.Value, table: :my_app_tenant_overrides

        @doc "The tenant for the current process, or the default."
        def current, do: get_or(:tenant, MyApp.Tenant.Default)

        @doc "Pin the tenant for this test and everything it spawns."
        def put(tenant), do: put_override(:tenant, tenant)
      end

  Register it once in `test/test_helper.exs`, exactly like a built-in:

      Ambient.start_servers([Ambient.Clock, MyApp.Tenant])

  ## What you get

  `use Ambient.Value, table: :some_table` defines:

    * `get_or/2` (imported macro) – the read. Returns the override if one is in
      scope, otherwise evaluates the fallback expression.
    * `@ambient_enabled` – whether this build compiled the machinery in, for
      values that need to drop a branch of their own.
    * `put_override/2`, `delete_override/1`, `delete_all/0` – the writers.
    * `overridden?/1` – whether an override is in scope for a key.
    * `allow/2` – grant a process outside the `$callers` chain access.
    * `set_shared/1`, `set_private/0` – shared mode for `async: false` tests.
    * `__ambient_table__/0` – so `Ambient.start_servers/1` accepts the module.

  All of them are `defoverridable`. `allow/2` and `set_shared/1` take a
  defaulted second/first argument, so `allow/1` and `set_shared/0` are exported
  too.

  A module holding a single value conventionally uses one sentinel key
  (`:clock`, `:tenant`); one holding many (like `Ambient.Config`) keys by name.

  ## `get_or/2` is a macro, on purpose

  It expands at compile time, so in a build that didn't opt into overrides
  (see `Ambient.ProcessOverride`) the whole lookup disappears and only the
  fallback expression remains:

      def current, do: get_or(:tenant, MyApp.Tenant.Default)
      # in a production build, compiles to exactly:
      def current, do: MyApp.Tenant.Default

  That is what keeps a wrapper free to use everywhere in production code. The
  fallback is only evaluated when there is no override, so
  `get_or(:key, expensive_call())` doesn't pay for the call it doesn't need.
  """

  @enabled Application.compile_env(:ambient, :enable_overrides, false)

  @doc false
  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)

    if not is_atom(table) do
      raise ArgumentError,
            "use Ambient.Value expects :table to be an atom, got: #{inspect(table)}"
    end

    # In a build without overrides every writer raises, so its success typing
    # is none(). Saying so here keeps consumers' dialyzer runs clean, and says
    # it once rather than in each generated module body.
    writes = if @enabled, do: quote(do: :ok), else: quote(do: no_return())

    quote do
      import Ambient.Value, only: [get_or: 2]

      @ambient_table unquote(table)

      # Exposed so a module can compile out a branch of its own – a clause that
      # would be provably dead in a disabled build. Use it in the module body:
      # it is a compile-time constant, so a runtime `if` on it is just dead code.
      @ambient_enabled unquote(@enabled)

      @doc false
      @spec __ambient_table__() :: atom()
      def __ambient_table__, do: @ambient_table

      @doc "Set a process-local override for `key`. Auto-cleaned when the process exits."
      @spec put_override(term(), term()) :: unquote(writes)
      def put_override(key, value) do
        Ambient.ProcessOverride.put(@ambient_table, key, value)
      end

      @doc "Drop this process's override for `key`. No-op if there isn't one."
      @spec delete_override(term()) :: :ok
      def delete_override(key) do
        Ambient.ProcessOverride.delete(@ambient_table, key)
      end

      @doc "Drop every override this process owns in this module's table."
      @spec delete_all() :: :ok
      def delete_all do
        Ambient.ProcessOverride.delete_all(@ambient_table)
      end

      @doc "Whether an override for `key` is in scope for the calling process."
      @spec overridden?(term()) :: boolean()
      def overridden?(key) do
        match?({:ok, _}, Ambient.ProcessOverride.fetch(@ambient_table, key))
      end

      @doc """
      Authorise `child_pid` to read `owner_pid`'s overrides. For long-lived
      processes that don't appear in the `$callers` chain.
      """
      # Both arities: the default-arg bridge head gets its own success typing,
      # so a spec covering only allow/2 leaves allow/1 flagged in a disabled build.
      @spec allow(pid()) :: unquote(writes)
      @spec allow(pid(), pid()) :: unquote(writes)
      def allow(child_pid, owner_pid \\ self()) do
        Ambient.ProcessOverride.allow(@ambient_table, child_pid, owner_pid)
      end

      @doc """
      Make `owner_pid`'s overrides the ones every process reads. `async: false`
      only – see `Ambient.ProcessOverride.set_shared/2`.
      """
      @spec set_shared() :: unquote(writes)
      @spec set_shared(pid()) :: unquote(writes)
      def set_shared(owner_pid \\ self()) do
        Ambient.ProcessOverride.set_shared(@ambient_table, owner_pid)
      end

      @doc "Return this module's table to private, process-scoped mode."
      @spec set_private() :: unquote(writes)
      def set_private do
        Ambient.ProcessOverride.set_private(@ambient_table)
      end

      # Includes the default-arg bridges (allow/1, set_shared/0) and
      # __ambient_table__/0 – leaving the last one out meant redefining it
      # produced only a "clause cannot match" warning while the generated one
      # silently won.
      defoverridable __ambient_table__: 0,
                     put_override: 2,
                     delete_override: 1,
                     delete_all: 0,
                     overridden?: 1,
                     allow: 1,
                     allow: 2,
                     set_shared: 0,
                     set_shared: 1,
                     set_private: 0
    end
  end

  @doc """
  Read the override for `key`, falling back to `fallback` when there is none.

  Imported by `use Ambient.Value`, and resolved against that module's table.
  A macro rather than a function: in a build without overrides compiled in it
  expands to `fallback` alone, so the wrapper costs nothing in production.

      def utc_now, do: get_or(:clock, DateTime.utc_now())
  """
  defmacro get_or(key, fallback) do
    if @enabled do
      quote do
        case Ambient.ProcessOverride.fetch(@ambient_table, unquote(key)) do
          {:ok, value} -> value
          :error -> unquote(fallback)
        end
      end
    else
      fallback
    end
  end
end
