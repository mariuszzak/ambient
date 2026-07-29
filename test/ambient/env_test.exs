defmodule Ambient.EnvTest do
  use ExUnit.Case, async: true

  alias Ambient.Env

  # A variable that really is set in the OS environment, so the tests can tell
  # "override" apart from "there was nothing there anyway".
  @real "AMBIENT_ENV_TEST_REAL"

  setup do
    System.put_env(@real, "real-value")
    on_exit(fn -> System.delete_env(@real) end)
    :ok
  end

  describe "get/2" do
    test "falls through to the real environment" do
      assert Env.get(@real) == "real-value"
      assert Env.get("AMBIENT_ENV_TEST_MISSING") == nil
      assert Env.get("AMBIENT_ENV_TEST_MISSING", "fallback") == "fallback"
    end

    test "an override wins over the real value" do
      Env.put(@real, "overridden")
      assert Env.get(@real) == "overridden"
      assert System.get_env(@real) == "real-value", "the real environment must be untouched"
    end

    test "an override supplies a value for a variable that isn't set" do
      Env.put("AMBIENT_ENV_TEST_NEW", "from-test")
      assert Env.get("AMBIENT_ENV_TEST_NEW") == "from-test"
      assert System.get_env("AMBIENT_ENV_TEST_NEW") == nil
    end

    test "put_all/1 accepts a map and a list of pairs" do
      Env.put_all(%{"AMBIENT_A" => "1"})
      Env.put_all([{"AMBIENT_B", "2"}])
      assert Env.get("AMBIENT_A") == "1"
      assert Env.get("AMBIENT_B") == "2"
    end
  end

  describe "fetch/1 and fetch!/1" do
    test "mirror System.fetch_env/1 semantics" do
      assert Env.fetch(@real) == {:ok, "real-value"}
      assert Env.fetch("AMBIENT_ENV_TEST_MISSING") == :error

      Env.put("AMBIENT_ENV_TEST_NEW", "v")
      assert Env.fetch("AMBIENT_ENV_TEST_NEW") == {:ok, "v"}
    end

    test "fetch!/1 raises System.EnvError when unset" do
      assert Env.fetch!(@real) == "real-value"
      assert_raise System.EnvError, fn -> Env.fetch!("AMBIENT_ENV_TEST_MISSING") end
    end
  end

  describe "unset/1 vs revert/1" do
    test "unset/1 overrides a real variable down to unset" do
      Env.unset(@real)
      assert Env.get(@real) == nil
      assert Env.get(@real, "default") == "default"
      assert Env.fetch(@real) == :error
      assert_raise System.EnvError, fn -> Env.fetch!(@real) end
      assert System.get_env(@real) == "real-value"
    end

    test "revert/1 drops the override, restoring the real value" do
      Env.put(@real, "overridden")
      Env.revert(@real)
      assert Env.get(@real) == "real-value"
    end

    test "revert/1 after unset/1 also restores the real value" do
      Env.unset(@real)
      Env.revert(@real)
      assert Env.get(@real) == "real-value"
    end

    test "reset/0 drops every override this process set" do
      Env.put(@real, "overridden")
      Env.put("AMBIENT_ENV_TEST_NEW", "x")
      Env.unset("AMBIENT_ENV_TEST_OTHER")

      assert :ok = Env.reset()

      assert Env.get(@real) == "real-value"
      assert Env.get("AMBIENT_ENV_TEST_NEW") == nil
      assert Env.get("AMBIENT_ENV_TEST_OTHER", "d") == "d"
    end
  end

  describe "isolation and inheritance" do
    test "a Task child inherits through $callers" do
      Env.put("AMBIENT_ENV_TEST_NEW", "inherited")
      assert Task.async(fn -> Env.get("AMBIENT_ENV_TEST_NEW") end) |> Task.await() == "inherited"
    end

    test "an unrelated process does not see the override" do
      Env.put(@real, "mine")
      parent = self()
      pid = spawn(fn -> send(parent, {:saw, Env.get(@real)}) end)
      assert_receive {:saw, "real-value"}
      Process.exit(pid, :kill)
    end

    test "allow/2 bridges a process outside the chain" do
      Env.put(@real, "granted")
      parent = self()

      pid =
        spawn(fn ->
          receive do: (:go -> send(parent, {:saw, Env.get(@real)}))
        end)

      Env.allow(pid)
      send(pid, :go)
      assert_receive {:saw, "granted"}
    end
  end
end
