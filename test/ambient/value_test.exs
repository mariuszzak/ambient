defmodule Ambient.ValueTest do
  @moduledoc """
  Exercises the extension point the way a consuming app would: a custom
  value module, registered and used with no help from Ambient beyond
  `use Ambient.Value`.
  """

  use ExUnit.Case, async: true

  defmodule Tenant do
    use Ambient.Value, table: :ambient_value_test_tenant

    @default :public

    def current, do: get_or(:tenant, @default)
    def put(tenant), do: put_override(:tenant, tenant)
    def reset, do: delete_override(:tenant)
  end

  setup do
    Ambient.start_servers([Tenant])
    on_exit(&Tenant.reset/0)
    :ok
  end

  test "start_servers/1 accepts the module, via the generated __ambient_table__/0" do
    assert Tenant.__ambient_table__() == :ambient_value_test_tenant
    assert :ets.whereis(:ambient_value_test_tenant) != :undefined
  end

  test "get_or/2 returns the fallback with no override, the value with one" do
    assert Tenant.current() == :public
    Tenant.put(:acme)
    assert Tenant.current() == :acme
  end

  defmodule Explosive do
    use Ambient.Value, table: :ambient_value_test_tenant

    # get_or/2 injects the fallback into the miss branch, so it must only run
    # when there is no override.
    def value, do: get_or(:boom, raise("fallback was evaluated"))
  end

  test "the fallback expression is only evaluated on a miss" do
    assert_raise RuntimeError, "fallback was evaluated", &Explosive.value/0

    Explosive.put_override(:boom, :from_override)
    assert Explosive.value() == :from_override
  end

  test "overrides inherit through $callers, like a built-in value module" do
    Tenant.put(:acme)
    assert Task.async(&Tenant.current/0) |> Task.await() == :acme
  end

  test "the generated allow/2 bridges a process outside the chain" do
    Tenant.put(:acme)
    parent = self()
    pid = spawn(fn -> receive do: (:go -> send(parent, {:saw, Tenant.current()})) end)

    Tenant.allow(pid)
    send(pid, :go)
    assert_receive {:saw, :acme}
  end

  test "the generated overridden?/1, delete_override/1 and delete_all/0" do
    refute Tenant.overridden?(:tenant)
    Tenant.put(:acme)
    assert Tenant.overridden?(:tenant)

    Tenant.delete_override(:tenant)
    refute Tenant.overridden?(:tenant)
    assert Tenant.current() == :public

    Tenant.put(:acme)
    Tenant.put_override(:other, :thing)
    assert :ok = Tenant.delete_all()
    refute Tenant.overridden?(:tenant)
    refute Tenant.overridden?(:other)
  end

  test "a read-modify-write read falls through when the server isn't started" do
    # The seeded-RNG shape: reads that advance state must degrade to their
    # fallback, not crash, when nobody called start_servers/1.
    defmodule Counter do
      use Ambient.Value, table: :ambient_value_test_never_started

      def bump do
        case Ambient.ProcessOverride.get_and_update(@ambient_table, :n, fn n -> {n, n + 1} end) do
          {:ok, n} -> n
          :error -> :no_override
        end
      end
    end

    assert Counter.bump() == :no_override
  end

  test "the generated writers raise Ambient.Error when the server isn't started" do
    defmodule Unstarted do
      use Ambient.Value, table: :ambient_value_test_unstarted
    end

    error = assert_raise Ambient.Error, fn -> Unstarted.put_override(:k, :v) end
    assert error.reason == :server_not_started
    assert error.table == :ambient_value_test_unstarted
  end

  test "the generated functions are overridable" do
    defmodule CustomAllow do
      use Ambient.Value, table: :ambient_value_test_custom

      # No default here – the generated allow/1 head already supplies it.
      def allow(_child, _owner), do: :refused
    end

    assert CustomAllow.allow(self()) == :refused
    assert CustomAllow.allow(self(), self()) == :refused
  end
end
