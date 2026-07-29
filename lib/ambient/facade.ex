defmodule Ambient.Facade do
  @moduledoc """
  Re-export another module's public functions under the using module's name.

  Handy for exposing an Ambient value under your own app's namespace without
  hand-writing – and having to maintain – a `defdelegate` list:

      defmodule MyApp.Clock do
        use Ambient.Facade, for: Ambient.Clock
      end

      MyApp.Clock.set(~U[2026-01-01 00:00:00Z])   # delegates to Ambient.Clock

  Delegates are derived from the target's public functions **at compile time**,
  so the facade never drifts when the target gains or loses a function.

  ## Options

    * `:for` – the target module to re-export (required).
    * `:only` – restrict to these functions, as names (`:set`) or name/arity
      pairs (`{:allow, 2}`). When omitted, every public function is re-exported.
    * `:except` – functions to skip, in the same shape. Applied after `:only`.

  Names beginning with `__` are skipped – with one exception:
  `__ambient_table__/0` is passed through when the target has it, so the facade
  can be handed to `Ambient.start_servers/1` and `Ambient.set_shared/2` in
  place of the value module it wraps. `:only` and `:except` don't apply to it.
  """

  @doc false
  defmacro __using__(opts) do
    target = opts |> Keyword.fetch!(:for) |> Macro.expand(__CALLER__)
    only = Keyword.get(opts, :only, nil)
    except = Keyword.get(opts, :except, [])

    Code.ensure_compiled!(target)

    table_passthrough =
      if function_exported?(target, :__ambient_table__, 0) do
        quote do
          @doc false
          @spec __ambient_table__() :: atom()
          def __ambient_table__, do: unquote(target).__ambient_table__()
        end
      end

    delegates =
      for {name, arity} <- target.__info__(:functions), include?(name, arity, only, except) do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          defdelegate unquote(name)(unquote_splicing(args)), to: unquote(target)
        end
      end

    [table_passthrough | delegates]
  end

  defp include?(name, arity, only, except) do
    not String.starts_with?(Atom.to_string(name), "__") and
      listed?(only, name, arity, true) and
      not listed?(except, name, arity, false)
  end

  # `default` is what an empty/absent list means: `only` absent → include all
  # (true); `except` absent → exclude none (false).
  defp listed?(nil, _name, _arity, default), do: default
  defp listed?(list, name, arity, _default), do: name in list or {name, arity} in list
end
