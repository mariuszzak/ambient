# Only compiled when Credo is available (it's an optional dependency).
if Code.ensure_loaded?(Credo.Check) do
  defmodule Ambient.Credo.NoDirectRandom do
    @moduledoc """
    Bans direct non-cryptographic randomness so it can't bypass the seed. Route
    shuffles, jitter, tiebreakers, and sampling through your RNG wrapper
    (`Ambient.Random`, or a `use Ambient.Facade` re-export).

        {Ambient.Credo.NoDirectRandom, []}
        {Ambient.Credo.NoDirectRandom, replacement: "MyApp.Random", exempt_suffixes: ["lib/my_app/random.ex"]}

    Flags `:rand.uniform|uniform_real|normal`, their state-threading `_s`
    variants (`:rand.uniform_s|uniform_real_s|normal_s`), `:rand.seed|seed_s`,
    and `Enum.shuffle|random|take_random`, in call and capture forms. The `_s`
    variants and `seed` take/return an explicit RNG state, so they dodge the
    process-override seed just as much as the plain reads. Never flags
    `:crypto.strong_rand_bytes/1` – credential material must stay on a
    non-seedable cryptographic RNG.
    """

    use Credo.Check,
      base_priority: :high,
      category: :warning,
      param_defaults: [replacement: "Ambient.Random", exempt_suffixes: ["lib/ambient/random.ex"]],
      explanations: [
        check: """
        Direct randomness reads bypass the RNG seed and make code paths
        flaky-by-design. Route through your RNG wrapper. Crypto-grade
        randomness for tokens (`:crypto.strong_rand_bytes/1`) is allowed.
        """,
        params: [
          replacement: "Your RNG wrapper module name, shown in the message.",
          exempt_suffixes: "File path suffixes exempt from the check."
        ]
      ]

    alias Ambient.Credo.MFAScanner
    alias Credo.Check.Params

    @banned [
      {:rand, :uniform, :any, "uniform/{0,1}"},
      {:rand, :uniform_real, :any, "uniform/0"},
      {:rand, :normal, :any, "normal/2"},
      # State-threading (`_s`) variants take/return an explicit RNG state, so
      # they dodge the process-override seed just as much as the plain reads –
      # a test can neither `seed/1` nor `allow/1` them. Map to the same wrapper
      # entry points.
      {:rand, :uniform_s, :any, "uniform/{0,1}"},
      {:rand, :uniform_real_s, :any, "uniform/0"},
      {:rand, :normal_s, :any, "normal/2"},
      # Seeding :rand directly (process-global or explicit state) sidesteps the
      # wrapper's own seed.
      {:rand, :seed, :any, "seed/1"},
      {:rand, :seed_s, :any, "seed/1"},
      {:Enum, :shuffle, 1, "shuffle/1"},
      {:Enum, :random, 1, "random/1"},
      {:Enum, :take_random, 2, "take_random/2"}
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
              "#{banned} bypasses the RNG seed. Use #{prefix}#{replacement}.#{suffix} instead " <>
                "(crypto-grade randomness may call :crypto.strong_rand_bytes/1 directly).",
            trigger: banned,
            line_no: line
          )
        end
      end
    end
  end
end
