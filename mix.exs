defmodule Ambient.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/mariuszzak/ambient"

  def project do
    [
      app: :ambient,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Ambient",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      # :credo is optional and `runtime: false`, but the bundled checks reference
      # it, so the PLT needs it or dialyzer reports unknown functions.
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix, :credo],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      test_coverage: [summary: [threshold: 90]],
      # `test/fixtures/*.exs` are scripts run by a test, not test files
      # themselves. (Elixir 1.19+; ignored on older versions.)
      test_ignore_filters: [~r"^test/fixtures/"]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      # dialyzer last: it's the slow one, and the first PLT build is minutes.
      check: ["format --check-formatted", "credo --strict", "test", "dialyzer"]
    ]
  end

  defp description do
    "Per-process Application.get_env overrides, so config-dependent tests can " <>
      "stay async: true – plus the same machinery for any ambient value of " <>
      "your own. Overrides cross process boundaries, never leak between " <>
      "concurrent tests, and compile out of production builds."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        Core: [
          Ambient,
          Ambient.Value,
          Ambient.Error,
          Ambient.ProcessOverride,
          Ambient.ProcessOverride.Server,
          Ambient.Supervisor,
          Ambient.Facade
        ],
        "Built-in values": [Ambient.Config, Ambient.Clock],
        "Credo checks": [Ambient.Credo.NoDirectConfig, Ambient.Credo.NoDirectClock]
      ]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Optional: only needed if you enable the bundled `Ambient.Credo.*` checks.
      # Consumers who don't use Credo pull nothing and the checks aren't compiled.
      {:credo, "~> 1.7", optional: true, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
