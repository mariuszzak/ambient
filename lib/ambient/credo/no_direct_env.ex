# Only compiled when Credo is available (it's an optional dependency). Consumers
# who don't use Credo pay nothing; those who do can enable this check.
if Code.ensure_loaded?(Credo.Check) do
  defmodule Ambient.Credo.NoDirectEnv do
    @moduledoc """
    Bans direct OS-environment reads so they can't bypass the env override.
    Route them through your env wrapper (`Ambient.Env`, or a
    `use Ambient.Facade` re-export of it).

        # .credo.exs – defaults target Ambient.Env
        {Ambient.Credo.NoDirectEnv, []}

        # or point it at your own wrapper
        {Ambient.Credo.NoDirectEnv, replacement: "MyApp.Env", exempt_suffixes: ["lib/my_app/env.ex"]}

    Flags `System.get_env/*`, `System.fetch_env/1`, `System.fetch_env!/1` and
    the Erlang `:os.getenv/*`, in call and capture forms.

    `System.put_env` and `System.delete_env` are flagged too: they mutate the
    whole VM, so a test using them is not `async: true`-safe. Use
    `Ambient.Env.put/2` and `Ambient.Env.unset/1`.

    > #### Boot-time reads {: .neutral}
    >
    > `config/runtime.exs` is evaluated once at boot, long before any override
    > exists, so reading `System.get_env/1` there is correct – exempt it via
    > `exempt_suffixes` if you lint your config files.
    """

    use Credo.Check,
      base_priority: :high,
      category: :warning,
      param_defaults: [replacement: "Ambient.Env", exempt_suffixes: ["lib/ambient/env.ex"]],
      explanations: [
        check: """
        Direct environment reads bypass the env test override, and
        `System.put_env/2` mutates the whole VM – concurrent `async: true`
        tests clobber each other and values leak into later tests. Route
        through your env wrapper instead.
        """,
        params: [
          replacement: "Your env wrapper module name, shown in the message.",
          exempt_suffixes:
            "File path suffixes exempt from the check (your wrapper's own file, " <>
              "and usually config/runtime.exs)."
        ]
      ]

    alias Ambient.Credo.MFAScanner
    alias Credo.Check.Params

    # {module, fun, arity_or_:any, suggested_suffix}
    @banned [
      {:System, :get_env, :any, "get/2"},
      {:System, :fetch_env, 1, "fetch/1"},
      {:System, :fetch_env!, 1, "fetch!/1"},
      {:System, :put_env, :any, "put/2"},
      {:System, :delete_env, 1, "unset/1"},
      {:os, :getenv, :any, "get/2"}
    ]

    @impl true
    def run(%SourceFile{} = source_file, params \\ []) do
      replacement = Params.get(params, :replacement, __MODULE__)
      exempt = Params.get(params, :exempt_suffixes, __MODULE__)

      if MFAScanner.exempt?(source_file, exempt) do
        []
      else
        issue_meta = IssueMeta.for(source_file, params)

        for {line, banned, suffix, prefix} <- MFAScanner.scan(source_file, @banned) do
          format_issue(issue_meta,
            message:
              "#{banned} bypasses the env override. Use #{prefix}#{replacement}.#{suffix} instead.",
            trigger: banned,
            line_no: line
          )
        end
      end
    end
  end
end
