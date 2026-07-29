defmodule Ambient.ErrorTest do
  use ExUnit.Case, async: true

  # The messages are what a developer sees when they hold Ambient wrong, so
  # each one is asserted to name the thing that fixes it.
  describe "message/1" do
    test ":overrides_disabled points at the config line" do
      msg = message(reason: :overrides_disabled, table: :some_table)
      assert msg =~ "disabled in this build"
      assert msg =~ ":some_table"
      assert msg =~ "enable_overrides: config_env() != :prod"
    end

    test ":overrides_disabled without a table omits the table clause" do
      msg = message(reason: :overrides_disabled)
      assert msg =~ "disabled in this build"
      refute msg =~ "cannot be written"
    end

    test ":server_not_started points at start_servers/1" do
      msg = message(reason: :server_not_started, table: :t)
      assert msg =~ "no Ambient override server for :t"
      assert msg =~ "Ambient.start_servers/1"
    end

    test "{:not_shared_owner, pid} names the owner and the way out" do
      owner = self()
      msg = message(reason: {:not_shared_owner, owner}, table: :t)
      assert msg =~ inspect(owner)
      assert msg =~ "shared mode"
      assert msg =~ "set_private"
    end

    test ":cant_allow_in_shared_mode explains why there's nothing to grant" do
      msg = message(reason: :cant_allow_in_shared_mode, table: :t)
      assert msg =~ "shared owner's values"
      assert msg =~ "set_private"
    end

    test ":not_a_value_module lists what is acceptable" do
      msg = message(reason: :not_a_value_module, table: Ambient.Nope)
      assert msg =~ "__ambient_table__/0"
      assert msg =~ "raw table atom"
    end

    test "{:server_start_failed, reason} includes the underlying reason" do
      msg = message(reason: {:server_start_failed, :eacces}, table: :t)
      assert msg =~ "could not start a server for :t"
      assert msg =~ ":eacces"
    end
  end

  test "carries reason and table as struct fields, for matching" do
    error = Ambient.Error.exception(reason: :server_not_started, table: :t)
    assert %Ambient.Error{reason: :server_not_started, table: :t} = error
  end

  test "requires a :reason" do
    assert_raise KeyError, fn -> Ambient.Error.exception([]) end
  end

  defp message(opts), do: opts |> Ambient.Error.exception() |> Exception.message()
end
