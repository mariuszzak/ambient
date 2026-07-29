defmodule Ambient.ProcessOverride.Server do
  @moduledoc """
  Owns one ETS table for `Ambient.ProcessOverride` and monitors every PID that
  writes an override into it. On `:DOWN`, the owning rows and any `{:allow, …}`
  rows pointing at the dead PID are cleared.

  Start one instance per override table from `test/test_helper.exs` – usually
  via `Ambient.start_servers/1` rather than calling this directly. Not part of
  the production supervision tree.

      {:ok, _} = Ambient.ProcessOverride.Server.start_link(table: :ambient_clock_overrides)
  """

  use GenServer

  @enabled Application.compile_env(:ambient, :enable_overrides, false)

  @doc """
  Start a `Server` that owns `:table` and registers itself under
  `ProcessOverride.server_name(table)`.

  Raises in builds that didn't opt into overrides – creating the table is what
  makes them reachable, so it's gated at compile time along with the writers.
  See `Ambient.ProcessOverride`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  if @enabled do
    def start_link(opts) do
      table = Keyword.fetch!(opts, :table)
      GenServer.start_link(__MODULE__, table, name: Ambient.ProcessOverride.server_name(table))
    end
  else
    def start_link(opts) do
      raise Ambient.Error, reason: :overrides_disabled, table: Keyword.fetch!(opts, :table)
    end
  end

  # `use GenServer` exports `init/1`, so gating only `start_link/1` would leave
  # `GenServer.start_link(Server, :some_table)` as an open door to the very
  # thing the switch exists to prevent: a live table in a build that opted out.
  @impl true
  if @enabled do
    def init(table) do
      ^table =
        :ets.new(table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      {:ok, %{table: table, monitors: %{}}}
    end
  else
    def init(table) do
      {:stop, Ambient.Error.exception(reason: :overrides_disabled, table: table)}
    end
  end

  @impl true
  def handle_cast({:monitor, pid}, state), do: {:noreply, monitor(state, pid)}

  # Catch-all: this table owner is a named, public server any process can reach,
  # so an unexpected message must not crash it (that would drop the ETS table
  # and silently void every override). Ignore instead.
  def handle_cast(_msg, state), do: {:noreply, state}

  # Monitor + insert together, on the Server's side of its own mailbox. A
  # client that monitored via cast and then inserted would race any :DOWN for
  # a pid that dies in the gap, orphaning the row permanently.
  @impl true
  def handle_call({:allow, child_pid, owner_pid}, _from, state) do
    state = monitor(state, child_pid)
    :ets.insert(state.table, {{:allow, child_pid}, owner_pid})
    {:reply, :ok, state}
  end

  def handle_call({:set_shared, owner_pid}, _from, state) do
    state = monitor(state, owner_pid)
    :ets.insert(state.table, {:mode, {:shared, owner_pid}})
    {:reply, :ok, state}
  end

  # Serialised here so concurrent read-modify-write callers can't lose each
  # other's updates – in shared mode they all target the same row.
  def handle_call({:get_and_update, owner, key, fun}, _from, state) do
    case :ets.lookup(state.table, {owner, key}) do
      [{_, current}] ->
        {value, updated} = fun.(current)
        :ets.insert(state.table, {{owner, key}, updated})
        {:reply, {:ok, value}, state}

      [] ->
        {:reply, :error, state}
    end
  end

  def handle_call(_msg, _from, state), do: {:reply, {:error, :unsupported}, state}

  defp monitor(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.match_delete(state.table, {{pid, :_}, :_})
    :ets.match_delete(state.table, {{:allow, :_}, pid})
    :ets.delete(state.table, {:allow, pid})
    # A crashed shared owner must not leave the whole suite globally
    # overridden, so drop back to private mode with it.
    :ets.match_delete(state.table, {:mode, {:shared, pid}})
    {:noreply, %{state | monitors: Map.delete(state.monitors, pid)}}
  end

  # Same reasoning as the handle_cast/2 catch-all: defining handle_info/2 at
  # all replaces the `use GenServer` default, so without this any stray message
  # crashes the server – and the restart hands back an *empty* table, silently
  # voiding every override in flight.
  def handle_info(_msg, state), do: {:noreply, state}
end
