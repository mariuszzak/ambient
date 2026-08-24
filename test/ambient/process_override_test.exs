defmodule Ambient.ProcessOverrideTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ambient.ProcessOverride, as: PO

  import Ambient.TestHelpers

  @table :ambient_core_test

  describe "self scope" do
    test "put then fetch returns the value" do
      assert :ok = PO.put(@table, :k, 42)
      assert PO.fetch(@table, :k) == {:ok, 42}
    end

    test "fetch returns :error when no override is set" do
      assert PO.fetch(@table, :never_set) == :error
    end

    test "delete removes the override" do
      PO.put(@table, :gone, 1)
      assert PO.fetch(@table, :gone) == {:ok, 1}
      assert :ok = PO.delete(@table, :gone)
      assert PO.fetch(@table, :gone) == :error
    end

    test "a later put overwrites the same key" do
      PO.put(@table, :ow, :first)
      PO.put(@table, :ow, :second)
      assert PO.fetch(@table, :ow) == {:ok, :second}
    end

    test "multiple keys per owner coexist; deleting one keeps the others" do
      PO.put(@table, :a, 1)
      PO.put(@table, :b, 2)
      assert PO.fetch(@table, :a) == {:ok, 1}
      assert PO.fetch(@table, :b) == {:ok, 2}
      PO.delete(@table, :a)
      assert PO.fetch(@table, :a) == :error
      assert PO.fetch(@table, :b) == {:ok, 2}
    end

    test "nil is a real overridden value, distinct from :error" do
      PO.put(@table, :maybe_nil, nil)
      assert PO.fetch(@table, :maybe_nil) == {:ok, nil}
    end

    property "put/fetch round-trips any term for any key" do
      check all(key <- term(), value <- term()) do
        PO.put(@table, {:prop, key}, value)
        assert PO.fetch(@table, {:prop, key}) == {:ok, value}
      end
    end
  end

  describe "production path (table not started)" do
    test "fetch returns :error and delete is a no-op" do
      assert PO.fetch(:ambient_nonexistent_table, :k) == :error
      assert PO.delete(:ambient_nonexistent_table, :k) == :ok
    end

    test "get_and_update/3 misses instead of raising" do
      # Regression: get_and_update/3 reached shared_owner/1 – a bare
      # :ets.lookup – before any existence check, so it raised ArgumentError
      # from ETS. Every read-modify-write draw goes through here, so forgetting
      # start_servers/1 crashed uniform/bytes/shuffle instead of letting them
      # fall through to :rand.
      assert PO.get_and_update(:ambient_nonexistent_table, :k, fn s -> {s, s} end) == :error
    end

    test "put raises a structured error when the server isn't started" do
      error = assert_raise Ambient.Error, fn -> PO.put(:ambient_unstarted_table, :k, :v) end
      assert error.reason == :server_not_started
      assert error.table == :ambient_unstarted_table
      assert Exception.message(error) =~ "Ambient.start_servers/1"
    end
  end

  describe "compile-time switch" do
    test "this build opted in" do
      # If this ever fails the whole suite is meaningless – every override
      # would silently fall through. The disabled side is covered by
      # `Ambient.DisabledBuildTest`.
      assert PO.enabled?()
    end
  end

  describe "server resilience" do
    test "a stray GenServer.call does not crash the table owner" do
      name = PO.server_name(@table)
      assert {:error, :unsupported} = GenServer.call(name, :bogus)
      assert Process.alive?(Process.whereis(name))
    end

    test "a stray info message does not crash the table owner" do
      # Regression: defining handle_info/2 replaces the `use GenServer` default,
      # so without a catch-all any stray message killed the server – and the
      # restart hands back an *empty* table, silently voiding every override in
      # flight. handle_cast/2 and handle_call/3 already guarded against this.
      Ambient.start_servers([:ambient_stray_info_test])
      pid = Process.whereis(PO.server_name(:ambient_stray_info_test))
      PO.put(:ambient_stray_info_test, :k, :v)

      send(pid, :stray_message)
      send(pid, {:DOWN, :not_a_ref, :process, self(), :nope, :extra_element})

      # round-trip through the server to be sure both were processed
      assert {:error, :unsupported} = GenServer.call(pid, :ping)

      assert Process.alive?(pid)
      assert PO.fetch(:ambient_stray_info_test, :k) == {:ok, :v}
    end

    test "a crashed server is restarted by the supervisor and the table recreated" do
      Ambient.start_servers([:ambient_restart_test])
      name = PO.server_name(:ambient_restart_test)
      pid = Process.whereis(name)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert eventually(fn ->
               new = Process.whereis(name)
               is_pid(new) and new != pid and :ets.whereis(:ambient_restart_test) != :undefined
             end)
    end
  end

  describe "cross-process inheritance" do
    test "a Task.async child inherits via the $callers chain" do
      PO.put(@table, :inherited, :yes)
      task = Task.async(fn -> PO.fetch(@table, :inherited) end)
      assert Task.await(task) == {:ok, :yes}
    end

    test "a nested Task inherits through a grandparent" do
      PO.put(@table, :deep, 7)

      task =
        Task.async(fn ->
          Task.async(fn -> PO.fetch(@table, :deep) end) |> Task.await()
        end)

      assert Task.await(task) == {:ok, 7}
    end

    test "allow/3 lets an unrelated process inherit" do
      PO.put(@table, :shared, 99)
      parent = self()

      # spawn (not Task) → no $callers link, so only allow/3 can bridge it
      pid =
        spawn(fn ->
          receive do
            :go -> send(parent, {:val, PO.fetch(@table, :shared)})
          end
        end)

      assert PO.fetch(@table, :shared) == {:ok, 99}
      :ok = PO.allow(@table, pid, self())
      send(pid, :go)
      assert_receive {:val, {:ok, 99}}
    end

    test "is key-aware: a nested spawn resolves a key owned by an older ancestor" do
      # parent owns :a; a Task owns :b in the same table; the Task's child must
      # still resolve :a from the parent, not latch onto the nearer Task.
      PO.put(@table, :a, "A-from-parent")

      outer =
        Task.async(fn ->
          PO.put(@table, :b, "B-from-task")
          Task.async(fn -> PO.fetch(@table, :a) end) |> Task.await()
        end)

      assert Task.await(outer) == {:ok, "A-from-parent"}
    end

    test "an allow cycle resolves to :error instead of hanging" do
      other = spawn(fn -> Process.sleep(:infinity) end)
      PO.allow(@table, self(), other)
      PO.allow(@table, other, self())
      # neither owns the key – must terminate, not spin forever
      assert PO.fetch(@table, :cycle_key) == :error
      Process.exit(other, :kill)
    end

    test "resolves through a recursive (2-hop) allow chain" do
      PO.put(@table, :chained, :ok3)
      parent = self()

      c = spawn(fn -> receive(do: (:go -> send(parent, {:c, PO.fetch(@table, :chained)}))) end)
      b = spawn(fn -> Process.sleep(:infinity) end)

      # C → B → self(owner). Neither B nor C is in C's $callers.
      PO.allow(@table, b, self())
      PO.allow(@table, c, b)

      send(c, :go)
      assert_receive {:c, {:ok, :ok3}}
      Process.exit(b, :kill)
    end
  end

  describe "isolation + cleanup" do
    test "concurrent owners do not see each other's overrides" do
      PO.put(@table, :iso, :mine)
      parent = self()

      other =
        spawn(fn ->
          # this process is not in our $callers and is not allowed
          send(parent, {:other, PO.fetch(@table, :iso)})
          Process.sleep(:infinity)
        end)

      assert_receive {:other, :error}
      Process.exit(other, :kill)
    end

    test "rows are cleared when the owning process dies" do
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          PO.put(@table, :ephemeral, :v)
          send(parent, :ready)
          Process.sleep(:infinity)
        end)

      assert_receive :ready
      assert :ets.match(@table, {{pid, :_}, :_}) != []

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      # the Server processes the :DOWN asynchronously
      assert eventually(fn -> :ets.match(@table, {{pid, :_}, :_}) == [] end)
    end

    test "allow rows pointing at a dead owner are cleared" do
      parent = self()

      {owner, ref} =
        spawn_monitor(fn ->
          PO.put(@table, :k, :v)
          send(parent, :ready)
          Process.sleep(:infinity)
        end)

      assert_receive :ready
      child = spawn(fn -> Process.sleep(:infinity) end)
      PO.allow(@table, child, owner)
      assert :ets.lookup(@table, {:allow, child}) == [{{:allow, child}, owner}]

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}

      assert eventually(fn -> :ets.lookup(@table, {:allow, child}) == [] end)
      Process.exit(child, :kill)
    end

    test "a read-only allowed child's allow row is cleared when the child dies" do
      PO.put(@table, :k, :v)
      {child, ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)
      # child never puts (read-only) – allow/3 must monitor it for cleanup
      PO.allow(@table, child, self())
      assert :ets.lookup(@table, {:allow, child}) != []

      Process.exit(child, :kill)
      assert_receive {:DOWN, ^ref, :process, ^child, _}
      assert eventually(fn -> :ets.lookup(@table, {:allow, child}) == [] end)
    end
  end
end
