defmodule Ambient.CredoChecksTest do
  use Credo.Test.Case

  alias Ambient.Credo.{NoDirectClock, NoDirectConfig, NoDirectEnv, NoDirectRandom}

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
    # pinning an exact arity never matched. `Enum.shuffle/1` is overwhelmingly
    # written piped, which meant NoDirectRandom missed its most common form.
    test "are flagged with the right arity, in every check" do
      assert [issue] =
               "def f(l), do: l |> Enum.shuffle()"
               |> to_source_file("lib/app/foo.ex")
               |> run_check(NoDirectRandom)

      assert issue.trigger == "Enum.shuffle/1"

      assert [%{trigger: "Enum.take_random/2"}] =
               "def f(l), do: l |> Enum.take_random(2)"
               |> to_source_file("lib/app/foo.ex")
               |> run_check(NoDirectRandom)

      assert [%{trigger: "System.fetch_env!/1"}] =
               ~S{def f(v), do: v |> System.fetch_env!()}
               |> to_source_file("lib/app/foo.ex")
               |> run_check(NoDirectEnv)

      assert [%{trigger: "Application.get_env"}] =
               "def f, do: :my_app |> Application.get_env(:k)"
               |> to_source_file("lib/app/foo.ex")
               |> run_check(NoDirectConfig, otp_app: :my_app)
    end

    test "are flagged once, not once per pipe stage" do
      assert [%{trigger: "Enum.shuffle/1"}] =
               "def f(l), do: l |> Enum.shuffle() |> Enum.take(2)"
               |> to_source_file("lib/app/foo.ex")
               |> run_check(NoDirectRandom)
    end

    test "leave innocent pipes alone" do
      "def f(l), do: l |> Enum.map(& &1) |> Enum.sort()"
      |> to_source_file("lib/app/foo.ex")
      |> run_check(NoDirectRandom)
      |> refute_issues()
    end
  end

  describe "NoDirectEnv" do
    test "flags System.get_env/1 and suggests Ambient.Env" do
      [issue] =
        "def f, do: System.get_env(\"HOME\")"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectEnv)

      assert issue.trigger == "System.get_env/1"
      assert issue.message =~ "Ambient.Env.get/2"
    end

    test "names functions that actually exist on the wrapper" do
      # Regression: the check suggested `Ambient.Env.delete/1`, which the
      # unset/1 rename had removed – so it handed developers a name that
      # doesn't compile. Getting this right is the check's whole job.
      [issue] =
        ~S|def f, do: System.delete_env("HOME")|
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectEnv)

      assert issue.message =~ "Ambient.Env.unset/1"
      assert function_exported?(Ambient.Env, :unset, 1)
    end

    test "flags System.put_env/2, which is VM-global and breaks async: true" do
      [issue] =
        ~S|def f, do: System.put_env("A", "1")|
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectEnv)

      assert issue.trigger == "System.put_env/2"
      assert issue.message =~ "Ambient.Env.put/2"
    end

    test "flags the capture form and Erlang :os.getenv/1" do
      [capture] =
        "def f, do: &System.fetch_env!/1"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectEnv)

      assert capture.trigger == "&System.fetch_env!/1"

      [erl] =
        ~S|def f, do: :os.getenv(~c"HOME")|
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectEnv)

      assert erl.trigger == ":os.getenv/1"
    end

    test "respects :replacement and :exempt_suffixes" do
      [issue] =
        "def f, do: System.get_env(\"HOME\")"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectEnv, replacement: "MyApp.Env")

      assert issue.message =~ "MyApp.Env.get/2"

      "def f, do: System.get_env(\"HOME\")"
      |> to_source_file("config/runtime.exs")
      |> run_check(NoDirectEnv, exempt_suffixes: ["config/runtime.exs"])
      |> refute_issues()
    end

    test "does not flag Ambient.Env itself" do
      "def f, do: System.get_env(\"HOME\")"
      |> to_source_file("lib/ambient/env.ex")
      |> run_check(NoDirectEnv)
      |> refute_issues()
    end
  end

  describe "NoDirectRandom" do
    test "flags :rand.uniform/1" do
      [issue] =
        "def f, do: :rand.uniform(10)"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectRandom)

      assert issue.trigger == ":rand.uniform/1"
      assert issue.message =~ "Ambient.Random.uniform"
    end

    test "flags the state-threading :rand.uniform_s/2 variant" do
      [issue] =
        "def f(s), do: :rand.uniform_s(10, s)"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectRandom)

      assert issue.trigger == ":rand.uniform_s/2"
      assert issue.message =~ "Ambient.Random.uniform"
    end

    test "flags :rand.normal_s/3" do
      [issue] =
        "def f(s), do: :rand.normal_s(0, 1, s)"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectRandom)

      assert issue.trigger == ":rand.normal_s/3"
      assert issue.message =~ "Ambient.Random.normal"
    end

    test "flags :rand.seed/2 and :rand.seed_s/2 (seeding bypasses the wrapper's own seed)" do
      [seed_issue] =
        "def f, do: :rand.seed(:exsss, {1, 2, 3})"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectRandom)

      assert seed_issue.trigger == ":rand.seed/2"
      assert seed_issue.message =~ "Ambient.Random.seed"

      [seed_s_issue] =
        "def f, do: :rand.seed_s(:exsss, {1, 2, 3})"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectRandom)

      assert seed_s_issue.trigger == ":rand.seed_s/2"
      assert seed_s_issue.message =~ "Ambient.Random.seed"
    end

    test "flags the &:rand.uniform_s/2 capture form" do
      [issue] =
        "def f, do: &:rand.uniform_s/2"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectRandom)

      assert issue.trigger == "&:rand.uniform_s/2"
    end

    test "does not flag the wrapper's own _s usage (Ambient.Random is exempt)" do
      "def f(s), do: :rand.uniform_s(10, s)"
      |> to_source_file("lib/ambient/random.ex")
      |> run_check(NoDirectRandom)
      |> refute_issues()
    end

    test "flags Enum.shuffle/1 but not Enum.map/2" do
      [issue] =
        "def f(l), do: Enum.shuffle(l)"
        |> to_source_file("lib/app/foo.ex")
        |> run_check(NoDirectRandom)

      assert issue.trigger == "Enum.shuffle/1"

      "def f(l), do: Enum.map(l, & &1)"
      |> to_source_file("lib/app/foo.ex")
      |> run_check(NoDirectRandom)
      |> refute_issues()
    end

    test "does not flag :crypto.strong_rand_bytes/1" do
      "def f, do: :crypto.strong_rand_bytes(16)"
      |> to_source_file("lib/app/foo.ex")
      |> run_check(NoDirectRandom)
      |> refute_issues()
    end

    test "does not flag Ambient.Random itself" do
      "def f(l), do: Enum.shuffle(l)"
      |> to_source_file("lib/ambient/random.ex")
      |> run_check(NoDirectRandom)
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
