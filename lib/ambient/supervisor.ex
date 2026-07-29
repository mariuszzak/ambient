defmodule Ambient.Supervisor do
  @moduledoc """
  Supervises the per-table `Ambient.ProcessOverride.Server` processes.

  Started (and populated) by `Ambient.start_servers/1`. Running the servers
  under a supervisor means a Server crash is **restarted and logged** rather
  than silently dropping its ETS table (which would make every override for
  that table fall through to real values with no test failure). The supervisor
  also contains the crash, so it doesn't propagate to the test runner.

  A restart recreates an *empty* table – in-flight overrides for that table are
  lost, but the table is immediately available again for subsequent tests.
  """

  use DynamicSupervisor

  @spec start_link() :: Supervisor.on_start()
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # The default 3-restarts-in-5-seconds would give up during a suite that
    # kills a Server on purpose (or runs under `--repeat-until-failure`), and
    # a DynamicSupervisor that gives up takes every override table with it.
    # These servers are cheap and restarting one is always the right move.
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 1_000_000, max_seconds: 1)
  end
end
