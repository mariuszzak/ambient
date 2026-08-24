defmodule Ambient.CredoChecksTest do
  use Credo.Test.Case

  alias Ambient.Credo.{NoDirectClock, NoDirectConfig}

  describe "NoDirectClock" do
    test "flags DateTime.utc_now/0 and suggests Ambient.Clock" do
      [issue] =
        "def f, do: DateTime.utc_now()"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectClock)

      assert issue.trigger == "DateTime.utc_now/0"
      assert issue.message =~ "Ambient.Clock.utc_now/0"
    end

    test "flags the &DateTime.utc_now/0 capture form" do
      [issue] =
        "def f, do: &DateTime.utc_now/0"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectClock)

      assert issue.trigger == "&DateTime.utc_now/0"
    end

    test "flags Erlang :os.timestamp/0" do
      [issue] =
        "def f, do: :os.timestamp()"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectClock)

      assert issue.trigger == ":os.timestamp/0"
    end

    test "does not flag Ambient.Clock itself" do
      "def f, do: DateTime.utc_now()"
      |> to_source_file("lib/ambient/clock.ex")
      |> run_check(NoDirectClock)
      |> refute_issues()
    end

    test "does not flag System.monotonic_time" do
      "def f, do: System.monotonic_time()"
      |> to_source_file("lib/app/foo.ex")
      |> run_check(NoDirectClock)
      |> refute_issues()
    end
  end

  describe "piped calls" do
    # Regression: a pipe leaves the receiver out of the call node, so an entry
    # pinning an exact arity never matched – and the piped form is a common way
    # to write these calls.
    test "are flagged with the right arity, in every check" do
      assert [%{trigger: "DateTime.now/1"}] =
               ~S{def f(zone), do: zone |> DateTime.now()}
               |> to_source_file("lib/app/foo.ex")
               |> run_check(NoDirectClock)

      assert [%{trigger: "Application.get_env"}] =
               "def f, do: :my_app |> Application.get_env(:k)"
               |> to_source_file("lib/app/foo.ex")
               |> run_check(NoDirectConfig, otp_app: :my_app)
    end

    test "are flagged once, not once per pipe stage" do
      assert [%{trigger: "Application.get_env"}] =
               "def f, do: :my_app |> Application.get_env(:k) |> to_string()"
               |> to_source_file("lib/app/foo.ex")
               |> run_check(NoDirectConfig, otp_app: :my_app)
    end

    test "leave innocent pipes alone" do
      "def f(l), do: l |> Enum.map(& &1) |> Enum.sort()"
      |> to_source_file("lib/app/foo.ex")
      |> run_check(NoDirectClock)
      |> refute_issues()
    end
  end

  describe "NoDirectConfig" do
    @params [otp_app: :my_app, replacement: "MyApp.Config"]

    test "flags Application.get_env for the configured otp_app" do
      [issue] =
        "def f, do: Application.get_env(:my_app, :x)"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectConfig, @params)

      assert issue.trigger == "Application.get_env"
      assert issue.message =~ "MyApp.Config"
    end

    test "does not flag other apps' config" do
      "def f, do: Application.get_env(:phoenix, :x)"
      |> to_source_file("lib/app/foo.ex")
      |> run_check(NoDirectConfig, @params)
      |> refute_issues()
    end

    test "does not flag compile_env or put_env" do
      "def f, do: Application.compile_env(:my_app, :x)"
      |> to_source_file("lib/a.ex")
      |> run_check(NoDirectConfig, @params)
      |> refute_issues()

      "def f, do: Application.put_env(:my_app, :x, 1)"
      |> to_source_file("lib/a.ex")
      |> run_check(NoDirectConfig, @params)
      |> refute_issues()
    end

    test "is a no-op when otp_app is not configured" do
      "def f, do: Application.get_env(:my_app, :x)"
      |> to_source_file("lib/a.ex")
      |> run_check(NoDirectConfig)
      |> refute_issues()
    end
  end
end
