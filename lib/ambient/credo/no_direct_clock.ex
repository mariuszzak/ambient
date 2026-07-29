# Only compiled when Credo is available (it's an optional dependency). Consumers
# who don't use Credo pay nothing; those who do can enable this check.
if Code.ensure_loaded?(Credo.Check) do
  defmodule Ambient.Credo.NoDirectClock do
    @moduledoc """
    Bans direct wall-clock reads so they can't bypass the clock override. Route
    every time-of-day call through your clock wrapper (`Ambient.Clock`, or a
    `use Ambient.Facade` re-export of it).

        # .credo.exs – defaults target Ambient.Clock
        {Ambient.Credo.NoDirectClock, []}

        # or point it at your own wrapper
        {Ambient.Credo.NoDirectClock, replacement: "MyApp.Clock", exempt_suffixes: ["lib/my_app/clock.ex"]}

    Flags `DateTime.utc_now/*`, `DateTime.now/1`, `Date.utc_today/0`,
    `NaiveDateTime.utc_now|local_now`, `Time.utc_now/*`, and the Erlang
    `:os`/`:erlang` time primitives, in call and capture forms. Ignores
    `System.monotonic_time` (elapsed duration, not wall-clock).
    """

    use Credo.Check,
      base_priority: :high,
      category: :warning,
      param_defaults: [replacement: "Ambient.Clock", exempt_suffixes: ["lib/ambient/clock.ex"]],
      explanations: [
        check: """
        Direct wall-clock reads bypass the clock test override and make code
        paths un-time-travellable. Route through your clock wrapper instead.
        """,
        params: [
          replacement: "Your clock wrapper module name, shown in the message.",
          exempt_suffixes: "File path suffixes exempt from the check (your wrapper's own file)."
        ]
      ]

    alias Ambient.Credo.MFAScanner
    alias Credo.Check.Params

    # {module, fun, arity_or_:any, suggested_suffix}
    @banned [
      {:DateTime, :utc_now, :any, "utc_now/0"},
      {:DateTime, :now, :any, "now/1"},
      {:DateTime, :now!, :any, "now/1"},
      {:Date, :utc_today, 0, "utc_today/0"},
      {:NaiveDateTime, :utc_now, :any, "naive_utc_now/0"},
      {:NaiveDateTime, :local_now, :any, "naive_utc_now/0"},
      {:Time, :utc_now, :any, "utc_now/0 |> DateTime.to_time()"},
      {:os, :timestamp, 0, "utc_now/0"},
      {:os, :system_time, :any, "utc_now/0"},
      {:erlang, :timestamp, 0, "utc_now/0"},
      {:erlang, :now, 0, "utc_now/0"},
      {:erlang, :system_time, :any, "utc_now/0"}
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
              "#{banned} bypasses the clock override. Use #{prefix}#{replacement}.#{suffix} instead.",
            trigger: banned,
            line_no: line
          )
        end
      end
    end
  end
end
