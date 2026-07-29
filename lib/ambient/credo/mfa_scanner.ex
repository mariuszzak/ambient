# Only compiled when Credo is available (optional dependency).
if Code.ensure_loaded?(Credo.Check) do
  defmodule Ambient.Credo.MFAScanner do
    @moduledoc false
    # Shared engine for the "route this call through a wrapper" checks
    # (NoDirectClock / NoDirectEnv / NoDirectRandom, plus the pipe handling in
    # NoDirectConfig). Scans a source file for banned
    # module/function/arity references in both call (`Mod.fun(...)`) and capture
    # (`&Mod.fun/N`) form, and returns findings the caller turns into issues.
    #
    # `banned` is a list of `{module_atom, fun_atom, arity_or_:any, suffix}`,
    # where `suffix` is the suggested replacement tail (e.g. "utc_now/0").
    #
    # Each finding is `{line, banned_label, suffix, prefix}` where `prefix` is
    # "" for a call and "&" for a capture, so the caller can render both the
    # flagged token and the suggested `#{prefix}#{Wrapper}.#{suffix}`.

    @typedoc "`{module, function, arity_or_:any, suggested_replacement_suffix}`"
    @type banned :: {module(), atom(), arity() | :any, String.t()}

    @type finding :: {pos_integer() | nil, String.t(), String.t(), String.t()}

    @doc """
    Whether `source_file` is exempt, i.e. its path ends with one of `suffixes`.
    Every check takes an `:exempt_suffixes` param for its own wrapper's file.
    """
    @spec exempt?(Credo.SourceFile.t(), [String.t()]) :: boolean()
    def exempt?(source_file, suffixes) do
      path = source_file.filename || ""
      Enum.any?(suffixes, &String.ends_with?(path, &1))
    end

    @doc """
    Rewrite a pipe chain into ordinary nested calls.

    A pipe leaves its receiver out of the call node, so `list |> Enum.shuffle()`
    looks like `Enum.shuffle/0` and slips past any banned entry pinning an exact
    arity – and `Enum.shuffle/1` is overwhelmingly written piped.
    """
    @spec unpipe(Macro.t()) :: Macro.t()
    def unpipe(ast) do
      [{first, _} | rest] = Macro.unpipe(ast)
      Enum.reduce(rest, first, fn {node, i}, acc -> Macro.pipe(acc, node, i) end)
    end

    @spec scan(Credo.SourceFile.t(), [banned()]) :: [finding()]
    def scan(source_file, banned) do
      Credo.Code.prewalk(source_file, &traverse(&1, &2, banned), [])
    end

    defp traverse({:|>, _, [_, _]} = ast, acc, banned) do
      # `prewalk` descends into the *children* of what we return but never
      # re-applies this function to the node itself, so match the outermost
      # call here; the inner ones are reached on the way down.
      traverse(unpipe(ast), acc, banned)
    end

    # Elixir call: `Mod.fun(args)`
    defp traverse({{:., _, [{:__aliases__, meta, [mod]}, fun]}, _, args} = ast, acc, banned)
         when is_list(args) do
      {ast, collect(acc, banned, meta, mod, fun, length(args), "")}
    end

    # Erlang call: `:mod.fun(args)`
    defp traverse({{:., meta, [mod, fun]}, _, args} = ast, acc, banned)
         when is_atom(mod) and is_atom(fun) and is_list(args) do
      {ast, collect(acc, banned, meta, mod, fun, length(args), "")}
    end

    # Elixir capture: `&Mod.fun/N` (return a stripped node so prewalk doesn't
    # also visit the inner call and double-fire)
    defp traverse(
           {:&, meta, [{:/, _, [{{:., _, [{:__aliases__, _, [mod]}, fun]}, _, []}, arity]}]},
           acc,
           banned
         )
         when is_integer(arity) do
      {{:__block__, [], []}, collect(acc, banned, meta, mod, fun, arity, "&")}
    end

    # Erlang capture: `&:mod.fun/N`
    defp traverse({:&, meta, [{:/, _, [{{:., _, [mod, fun]}, _, []}, arity]}]}, acc, banned)
         when is_atom(mod) and is_atom(fun) and is_integer(arity) do
      {{:__block__, [], []}, collect(acc, banned, meta, mod, fun, arity, "&")}
    end

    defp traverse(ast, acc, _banned), do: {ast, acc}

    defp collect(acc, banned, meta, mod, fun, arity, prefix) do
      case lookup(banned, mod, fun, arity) do
        nil ->
          acc

        suffix ->
          [{meta[:line], "#{prefix}#{module_label(mod)}.#{fun}/#{arity}", suffix, prefix} | acc]
      end
    end

    defp lookup(banned, mod, fun, arity) do
      Enum.find_value(banned, fn
        {^mod, ^fun, ^arity, suffix} -> suffix
        {^mod, ^fun, :any, suffix} -> suffix
        _ -> nil
      end)
    end

    defp module_label(mod) do
      case Atom.to_string(mod) do
        "Elixir." <> rest -> rest
        <<first, _::binary>> = name when first in ?A..?Z -> name
        other -> ":" <> other
      end
    end
  end
end
