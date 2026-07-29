defmodule AmbientTest do
  use ExUnit.Case, async: true

  alias Ambient.ProcessOverride, as: PO

  describe "start_servers/1" do
    test "starts a server for a raw table atom and is idempotent" do
      assert :ok = Ambient.start_servers([:ambient_start_servers_test])
      assert :ok = Ambient.start_servers([:ambient_start_servers_test])
      # the table now exists and is usable
      assert Ambient.ProcessOverride.fetch(:ambient_start_servers_test, :k) == :error
    end

    test "accepts a value module (already started in test_helper)" do
      assert :ok = Ambient.start_servers([Ambient.Clock, Ambient.Random])
    end

    test "raises on a module-looking atom that isn't a valid value module" do
      for bogus <- [Ambient.NoSuchValue, Enum] do
        error = assert_raise Ambient.Error, fn -> Ambient.start_servers([bogus]) end
        assert error.reason == :not_a_value_module
        assert error.table == bogus
        assert Exception.message(error) =~ "not a valid Ambient value module"
      end
    end
  end

  describe "accepting a single value module" do
    test "start_servers/1, set_shared/2 and set_private/1 take one or a list" do
      assert :ok = Ambient.start_servers(:ambient_single_arg_test)
      assert :ets.whereis(:ambient_single_arg_test) != :undefined

      assert :ok = Ambient.set_shared(:ambient_single_arg_test)
      assert PO.mode(:ambient_single_arg_test) == {:shared, self()}

      assert :ok = Ambient.set_private(:ambient_single_arg_test)
      assert PO.mode(:ambient_single_arg_test) == :private
    end

    test "a non-atom, non-list argument raises :not_a_value_module rather than FunctionClauseError" do
      for bad <- ["a string", 42, nil] do
        error = assert_raise Ambient.Error, fn -> Ambient.set_shared(bad) end
        assert error.reason == :not_a_value_module
      end
    end
  end
end
