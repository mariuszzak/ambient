defmodule Ambient.DisabledBuildTest do
  @moduledoc """
  The compile-time switch can't be exercised from inside this suite – the
  suite *is* an enabled build. So shell out to a `MIX_ENV=prod` run, where
  `config/config.exs` resolves `enable_overrides` to false, and assert the
  disabled clauses there.

  Tagged `:disabled_build` so it can be excluded (`mix test --exclude
  disabled_build`) when the nested compile isn't wanted.
  """

  use ExUnit.Case, async: false

  @moduletag :disabled_build
  # Cold runs compile Ambient into `_build/prod` first.
  @moduletag timeout: 120_000

  @script "test/fixtures/disabled_build_check.exs"

  test "a build without overrides cannot hold one, and bytes/1 is crypto-only" do
    {output, status} =
      System.cmd("mix", ["run", @script],
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert status == 0, "#{@script} failed under MIX_ENV=prod:\n#{output}"
    assert output =~ "disabled-build checks passed"
  end
end
