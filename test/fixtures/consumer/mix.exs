defmodule Consumer.MixProject do
  use Mix.Project

  # A stand-in for a real consuming app, used by CI to compile Ambient *as a
  # dependency* with `--warnings-as-errors` in both envs, and to run Dialyzer
  # over it. Neither failure mode shows up when Ambient is compiled on its own:
  # a disabled build whose `fetch/2` is inferred as constant `:error` makes
  # every consumer's `{:ok, _}` branch unreachable, and the generated value module
  # writers' success typings land in the *consumer's* modules. Both are
  # warnings in their code, not ours.
  def project do
    [
      app: :consumer,
      version: "0.0.0",
      elixir: "~> 1.15",
      deps: [
        {:ambient, path: "../../.."},
        {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
