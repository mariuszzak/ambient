defmodule Ambient.SharedModeTest do
  @moduledoc """
  Shared mode is global to a table, so these tests must not run alongside
  anything else touching it – hence `async: false`, which ExUnit runs only
  after every async module has finished. Most use a dedicated `@table`; the
  cases that exercise `Ambient.set_shared/2` end to end necessarily flip the
  real `Ambient.Clock` and `Ambient.TestCounter` tables, and restore them in
  `on_exit`. Do not make this file `async: true`.
  """

  use ExUnit.Case, async: false

  alias Ambient.ProcessOverride, as: PO

  import Ambient.TestHelpers

  @table :ambient_shared_test

  setup do
    Ambient.start_servers([@table])
    on_exit(fn -> PO.set_private(@table) end)
    :ok
  end

  defp unrelated(fun) do
    parent = self()
    # spawn, not Task – no $callers link, so nothing but shared mode can bridge it
    pid = spawn(fn -> send(parent, {:reply, fun.()}) end)
    assert_receive {:reply, value}
    Process.exit(pid, :kill)
    value
  end

  describe "mode/1" do
    test "reports :private by default and after set_private/1" do
      assert PO.mode(@table) == :private
      PO.set_shared(@table)
      assert PO.mode(@table) == {:shared, self()}
      PO.set_private(@table)
      assert PO.mode(@table) == :private
    end

    test "reports :private for a table that doesn't exist" do
      assert PO.mode(:ambient_no_such_table) == :private
    end
  end

  describe "reads" do
    test "an unrelated process reads the shared owner's value" do
      PO.put(@table, :k, :shared_value)
      assert unrelated(fn -> PO.fetch(@table, :k) end) == :error

      PO.set_shared(@table)
      assert unrelated(fn -> PO.fetch(@table, :k) end) == {:ok, :shared_value}
    end

    test "the shared owner wins over a reader's own pre-existing row" do
      # Rows written before the switch must not shadow the shared owner, or
      # "everyone sees the same value" wouldn't hold.
      parent = self()

      other =
        spawn(fn ->
          PO.put(@table, :k, :mine)
          send(parent, :ready)
          receive do: (:go -> send(parent, {:reply, PO.fetch(@table, :k)}))
        end)

      assert_receive :ready
      PO.put(@table, :k, :owners)
      PO.set_shared(@table)

      send(other, :go)
      assert_receive {:reply, {:ok, :owners}}
      Process.exit(other, :kill)
    end

    test "a key the shared owner never set still misses" do
      PO.set_shared(@table)
      assert unrelated(fn -> PO.fetch(@table, :never_set) end) == :error
    end

    test "set_private/1 restores per-process resolution, keeping the values" do
      PO.put(@table, :k, :v)
      PO.set_shared(@table)
      assert unrelated(fn -> PO.fetch(@table, :k) end) == {:ok, :v}

      PO.set_private(@table)
      assert unrelated(fn -> PO.fetch(@table, :k) end) == :error
      assert PO.fetch(@table, :k) == {:ok, :v}
    end
  end

  describe "writes" do
    test "the shared owner may still write" do
      PO.set_shared(@table)
      assert :ok = PO.put(@table, :k, :updated)
      assert unrelated(fn -> PO.fetch(@table, :k) end) == {:ok, :updated}
    end

    test "anyone else raises {:not_shared_owner, owner}" do
      owner = self()
      PO.set_shared(@table)

      assert {:error, %Ambient.Error{} = error} =
               unrelated(fn ->
                 try do
                   PO.put(@table, :k, :sneaky)
                 rescue
                   e -> {:error, e}
                 end
               end)

      assert error.reason == {:not_shared_owner, owner}
      assert error.table == @table
      assert Exception.message(error) =~ "shared mode"
    end

    test "allow/3 is refused – there is nothing left to grant" do
      PO.set_shared(@table)
      child = spawn(fn -> Process.sleep(:infinity) end)

      error = assert_raise Ambient.Error, fn -> PO.allow(@table, child, self()) end
      assert error.reason == :cant_allow_in_shared_mode
      Process.exit(child, :kill)
    end

    test "set_shared/2 is idempotent and the owner can hand over" do
      other = spawn(fn -> Process.sleep(:infinity) end)
      PO.set_shared(@table)
      PO.set_shared(@table)
      assert PO.mode(@table) == {:shared, self()}

      PO.set_shared(@table, other)
      assert PO.mode(@table) == {:shared, other}
      Process.exit(other, :kill)
    end

    test "a non-owner can't steal the table with set_shared/2" do
      owner = self()
      PO.set_shared(@table)

      assert {:error, %Ambient.Error{reason: {:not_shared_owner, ^owner}}} =
               unrelated(fn ->
                 try do
                   PO.set_shared(@table, self())
                 rescue
                   e -> {:error, e}
                 end
               end)

      assert PO.mode(@table) == {:shared, owner}
    end

    test "set_private/1 is deliberately open, so on_exit (another process) can restore it" do
      PO.set_shared(@table)
      assert unrelated(fn -> PO.set_private(@table) end) == :ok
      assert PO.mode(@table) == :private
    end
  end

  describe "cleanup" do
    test "the table reverts to private when the shared owner dies" do
      {owner, ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)
      PO.set_shared(@table, owner)
      assert PO.mode(@table) == {:shared, owner}

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}

      # the Server handles the :DOWN asynchronously
      assert eventually(fn -> PO.mode(@table) == :private end)
    end

    test "a monitored non-owner dying leaves shared mode alone" do
      # The process must be one this table's Server actually monitors, or the
      # test proves nothing: it writes a row first, then the table goes shared.
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          PO.put(@table, :theirs, :v)
          send(parent, :ready)
          Process.sleep(:infinity)
        end)

      assert_receive :ready
      PO.set_shared(@table)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert eventually(fn -> :ets.match(@table, {{pid, :_}, :_}) == [] end)
      assert PO.mode(@table) == {:shared, self()}
    end

    test "an owner that dies in the set_shared/2 window doesn't strand the table" do
      # Regression: monitor-by-cast then insert-from-the-client raced any :DOWN
      # for a pid dying in the gap, leaving the table shared to a dead pid where
      # every write raised until someone called set_private/1.
      for _ <- 1..500 do
        PO.set_private(@table)
        owner = spawn(fn -> :ok end)
        ref = Process.monitor(owner)
        PO.set_shared(@table, owner)

        assert_receive {:DOWN, ^ref, :process, ^owner, _}
        _ = :sys.get_state(PO.server_name(@table))

        assert PO.mode(@table) == :private
      end
    end
  end

  describe "read-modify-write values" do
    test "a read that writes works from every process under shared mode" do
      Ambient.start_servers([Ambient.TestCounter])
      Ambient.TestCounter.start(0)
      Ambient.set_shared([Ambient.TestCounter])
      on_exit(fn -> Ambient.set_private([Ambient.TestCounter]) end)

      # Regression: the write-back used to be a plain put/3, so every non-owner
      # read raised {:not_shared_owner, _} – i.e. the feature was unusable for
      # exactly the values that need it.
      assert Task.async(fn -> Ambient.TestCounter.next() end) |> Task.await() == 0
      assert unrelated(fn -> Ambient.TestCounter.next() end) == 1
      assert Ambient.TestCounter.next() == 2
    end

    test "concurrent reads don't lose each other's updates" do
      # Regression: the write-back was a plain fetch-then-put on a row every
      # process shares, so two concurrent reads saw the same state, computed
      # the same result and overwrote each other. Measured before the fix:
      # 99 duplicates in 200 reads.
      Ambient.start_servers([Ambient.TestCounter])
      Ambient.TestCounter.start(0)
      Ambient.set_shared([Ambient.TestCounter])
      on_exit(fn -> Ambient.set_private([Ambient.TestCounter]) end)

      draws =
        1..200
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Process.sleep(0)
            Ambient.TestCounter.next()
          end)
        end)
        |> Task.await_many(:infinity)

      assert Enum.sort(draws) == Enum.to_list(0..199)
    end

    test "a raising fun surfaces in the caller and leaves the table intact" do
      # Regression: `fun` runs on the Server's side of the mailbox, so an
      # exception inside it killed the table owner. The caller saw an :exit
      # rather than its own error, and the restart handed back an *empty*
      # table – silently voiding every override in flight, suite-wide.
      PO.put(@table, :n, 1)
      PO.set_shared(@table)
      tid = :ets.whereis(@table)

      assert_raise RuntimeError, "boom", fn ->
        PO.get_and_update(@table, :n, fn _ -> raise "boom" end)
      end

      # Same for a callback that simply returns the wrong shape.
      assert_raise MatchError, fn ->
        PO.get_and_update(@table, :n, fn n -> n end)
      end

      assert :ets.whereis(@table) == tid, "the table was dropped and rebuilt"
      assert PO.mode(@table) == {:shared, self()}
      assert PO.fetch(@table, :n) == {:ok, 1}
      assert PO.get_and_update(@table, :n, &{&1, &1 + 1}) == {:ok, 1}
    end

    test "the state advances globally rather than forking per process" do
      Ambient.start_servers([Ambient.TestCounter])
      Ambient.TestCounter.start(0)
      Ambient.set_shared([Ambient.TestCounter])
      on_exit(fn -> Ambient.set_private([Ambient.TestCounter]) end)

      draws = for _ <- 1..4, do: unrelated(fn -> Ambient.TestCounter.next() end)
      assert draws == [0, 1, 2, 3], "shared mode should advance one value, not fork it"
    end
  end

  describe "Ambient.set_shared/2 and set_private/1" do
    test "accept value modules, and the built-ins honour the mode" do
      frozen = ~U[1999-12-31 23:59:59Z]
      Ambient.Clock.set(frozen)
      assert unrelated(fn -> Ambient.Clock.utc_now() end) != frozen

      Ambient.set_shared([Ambient.Clock])
      on_exit(fn -> Ambient.set_private([Ambient.Clock]) end)

      assert unrelated(fn -> Ambient.Clock.utc_now() end) == frozen

      Ambient.set_private([Ambient.Clock])
      assert unrelated(fn -> Ambient.Clock.utc_now() end) != frozen
    end

    test "reject an invalid value module, like start_servers/1" do
      error = assert_raise Ambient.Error, fn -> Ambient.set_shared([Ambient.Nope]) end
      assert error.reason == :not_a_value_module
    end
  end
end
