%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        # `test/fixtures/consumer` is a stand-in consuming app, not this
        # project's source – it exists to be compiled, not to be linted.
        excluded: [~r"/_build/", ~r"/deps/", ~r"test/fixtures/consumer/"]
      },
      strict: true,
      # NOTE: the bundled `Ambient.Credo.*` checks are a feature for *consumer*
      # apps – they are intentionally NOT enabled here. On this repo they'd be
      # inert (the only legit callers of the primitives are the wrappers they
      # exempt) and would misfire on tests that assert the real-clock/RNG
      # fall-through. Their behaviour is covered by `credo_checks_test.exs`.
      checks: %{}
    }
  ]
}
