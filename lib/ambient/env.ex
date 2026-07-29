defmodule Ambient.Env do
  @moduledoc """
  Overridable OS environment variables.

  In production `get/2` is `System.get_env/2`. In tests, `put/2` sets a value
  for the calling process and everything it spawns – without touching the
  actual environment.

  ## Why not `System.put_env/2`?

  It mutates the whole VM. Two `async: true` tests setting the same variable
  clobber each other, and a leaked value survives into every later test in the
  run; `on_exit` cleanup is easy to forget and easy to get wrong when a test
  fails midway. `Ambient.Env.put/2` is process-scoped, inherited through the
  `$callers` chain, and cleared automatically when the process exits – and the
  real OS environment is never touched, so a concurrent test reading the same
  variable still sees the real value.

  This is the same argument `Ambient.Config` makes against
  `Application.put_env/3`, applied one layer down.

  ## Production code

      Ambient.Env.get("DATABASE_URL")
      Ambient.Env.get("PORT", "4000")
      Ambient.Env.fetch!("SECRET_KEY_BASE")

  Read variables through these rather than `System.get_env/1` anywhere the
  value should be testable. `Ambient.Credo.NoDirectEnv` can enforce it.

  > #### Runtime reads only {: .warning}
  >
  > An override can only affect a read that happens *while it is in scope*.
  > Config resolved at boot (`config/runtime.exs`) or at compile time has
  > already been read, so overriding the variable later changes nothing. Wrap
  > the read in a function your code calls when it needs the value.

  ## Test usage

      Ambient.Env.put("FEATURE_X", "true")
      Ambient.Env.put_all(%{"REGION" => "eu-west-1", "TIER" => "premium"})
      Ambient.Env.unset("HOME")            # override it as absent, though it is set
      Ambient.Env.revert("HOME")           # drop the override, see the real value
      Ambient.Env.reset()                  # drop every override this process set

      # for a long-lived process that reads env in its own process:
      Ambient.Env.allow(genserver_pid)

  Register the table once in `test/test_helper.exs`:

      Ambient.start_servers([Ambient.Env])
  """

  use Ambient.Value, table: :ambient_env_overrides

  # `unset/1` records "this variable is unset" rather than removing the row, so
  # a test can override a variable that *is* set in the real environment down
  # to absent. `revert/1` and `reset/0` are what remove rows.
  @unset :__ambient_env_unset__

  @doc """
  The value of environment variable `var`, or `default` when it is unset.

  Delegates to `System.get_env/2` unless overridden – and in a build without
  overrides compiled in, *is* `System.get_env/2`.
  """
  @spec get(String.t()) :: term()
  @spec get(String.t(), term()) :: term()
  if @ambient_enabled do
    def get(var, default \\ nil) when is_binary(var) do
      case get_or(var, System.get_env(var, default)) do
        @unset -> default
        value -> value
      end
    end
  else
    # No override can exist, so the `@unset` clause would be provably dead –
    # which the compiler rightly reports. `get/2` *is* `System.get_env/2` here.
    def get(var, default \\ nil) when is_binary(var), do: System.get_env(var, default)
  end

  @doc """
  `{:ok, value}` if `var` is set (or overridden), `:error` otherwise. Mirrors
  `System.fetch_env/1`.
  """
  @spec fetch(String.t()) :: {:ok, String.t()} | :error
  def fetch(var) when is_binary(var) do
    case get(var, nil) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  @doc """
  The value of `var`, raising if it is unset. Mirrors `System.fetch_env!/1`,
  including the exception type.
  """
  @spec fetch!(String.t()) :: String.t()
  def fetch!(var) when is_binary(var) do
    case fetch(var) do
      {:ok, value} -> value
      :error -> raise System.EnvError, env: var
    end
  end

  @doc """
  Override `var` for this process and everything it spawns. The real
  environment is untouched.
  """
  if @ambient_enabled do
    @spec put(String.t(), String.t()) :: :ok
  else
    @spec put(String.t(), String.t()) :: no_return()
  end

  def put(var, value) when is_binary(var) and is_binary(value) do
    put_override(var, value)
  end

  @doc """
  Override several variables at once. Takes anything enumerating
  `{name, value}` pairs of binaries – a map or a list. Not a keyword list:
  variable names are strings, not atoms.
  """
  if @ambient_enabled do
    @spec put_all(Enumerable.t()) :: :ok
  else
    @spec put_all(Enumerable.t()) :: no_return()
  end

  def put_all(vars) do
    Enum.each(vars, fn {var, value} -> put(var, value) end)
  end

  @doc """
  Override `var` as **unset** for this process, whatever the real environment
  says. `get/2` then returns its default and `fetch/1` returns `:error`.

  This is how you test the "variable absent" path for something that really is
  set. Note it *writes* an override; to drop one and fall back to the real
  value, use `revert/1`.
  """
  if @ambient_enabled do
    @spec unset(String.t()) :: :ok
  else
    @spec unset(String.t()) :: no_return()
  end

  def unset(var) when is_binary(var) do
    put_override(var, @unset)
  end

  @doc """
  Drop this process's override for `var`, so `get/2` resolves normally again.

  "Normally" means the usual chain: if an ancestor still has an override for
  `var`, that one applies; only when nothing is left does the real environment
  show through.
  """
  @spec revert(String.t()) :: :ok
  def revert(var) when is_binary(var) do
    delete_override(var)
  end

  @doc """
  Drop every override this process set. Like `revert/1`, an inherited override
  from an ancestor still applies afterwards.
  """
  @spec reset() :: :ok
  def reset, do: delete_all()
end
