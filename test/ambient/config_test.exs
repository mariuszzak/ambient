defmodule Ambient.ConfigTest do
  use ExUnit.Case, async: true

  alias Ambient.TestConfig, as: Config

  describe "fallback to Application env" do
    test "get/2 reads Application.get_env when no override is set" do
      key = unique_key()
      put_app_env(key, "app-value")

      assert Config.get(key) == "app-value"
    end

    test "get/2 returns the default when unset" do
      assert Config.get(:definitely_unset, :fallback) == :fallback
    end
  end

  describe "override layer" do
    test "put_override/2 wins over Application env" do
      key = unique_key()
      put_app_env(key, "app-value")

      Config.put_override(key, "override-value")
      assert Config.get(key) == "override-value"
    end

    test "an override to nil wins over the default (set-to-nil ≠ unset)" do
      key = unique_key()
      Config.put_override(key, nil)
      assert Config.get(key, :some_default) == nil
    end

    test "delete_override/1 drops the override (falls back to the default)" do
      Config.put_override(:droppable, "override")
      assert Config.get(:droppable) == "override"
      assert :ok = Config.delete_override(:droppable)
      assert Config.get(:droppable, :fallback) == :fallback
    end

    test "overridden?/1 reflects whether a key is overridden" do
      key = unique_key()
      refute Config.overridden?(key)
      Config.put_override(key, 1)
      assert Config.overridden?(key)
    end

    test "overrides are isolated per process (async-safe)" do
      Config.put_override(:shared_key, :mine)
      parent = self()

      other =
        spawn(fn ->
          send(parent, {:other, Config.get(:shared_key, :default)})
          Process.sleep(:infinity)
        end)

      assert_receive {:other, :default}
      assert Config.get(:shared_key) == :mine
      Process.exit(other, :kill)
    end
  end

  describe "allow/2" do
    test "a GenServer can read the test's override once allowed" do
      Config.put_override(:gs_key, :from_test)
      {:ok, pid} = Agent.start(fn -> nil end)
      Config.allow(pid)

      assert Agent.get(pid, fn _ -> Config.get(:gs_key, :default) end) == :from_test
    end
  end

  test "__ambient_table__/0 derives from the otp_app" do
    assert Config.__ambient_table__() == :ambient_config_overrides_ambient
  end

  describe "domain verbs" do
    test "put/2 mirrors put_override/2" do
      assert :ok = Config.put(:verb_key, :from_put)
      assert Config.get(:verb_key) == :from_put
      assert Config.overridden?(:verb_key)
    end

    test "revert/1 drops one override, reset/0 drops them all" do
      Config.put(:a, 1)
      Config.put(:b, 2)

      assert :ok = Config.revert(:a)
      refute Config.overridden?(:a)
      assert Config.overridden?(:b)

      assert :ok = Config.reset()
      refute Config.overridden?(:b)
    end

    test "reverting falls back to the application environment" do
      Application.put_env(:ambient, :verb_fallback, :from_app)
      on_exit(fn -> Application.delete_env(:ambient, :verb_fallback) end)

      Config.put(:verb_fallback, :from_test)
      assert Config.get(:verb_fallback) == :from_test
      Config.revert(:verb_fallback)
      assert Config.get(:verb_fallback) == :from_app
    end
  end

  defp unique_key, do: :"cfg_#{System.unique_integer([:positive])}"

  defp put_app_env(key, value) do
    Application.put_env(:ambient, key, value)
    on_exit(fn -> Application.delete_env(:ambient, key) end)
  end
end
