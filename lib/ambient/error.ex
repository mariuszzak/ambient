defmodule Ambient.Error do
  @moduledoc """
  The exception every Ambient misuse raises, carrying a machine-readable
  `:reason` alongside the human-readable message.

  Match on `:reason` rather than on message text – the wording is not part of
  the contract:

      try do
        Ambient.ProcessOverride.put(table, :k, :v)
      rescue
        e in Ambient.Error ->
          case e.reason do
            :overrides_disabled -> :skip
            :server_not_started -> start_and_retry()
          end
      end

  ## Reasons

    * `:overrides_disabled` – the build didn't opt into the override machinery
      (`config :ambient, enable_overrides: …`). See `Ambient.ProcessOverride`.
    * `:server_not_started` – no `Ambient.ProcessOverride.Server` owns this
      table; call `Ambient.start_servers/1` first.
    * `{:not_shared_owner, pid}` – the table is in shared mode and only `pid`
      may write to it.
    * `:cant_allow_in_shared_mode` – `allow/3` is meaningless while a table is
      shared, since every process already reads the shared owner's values.
    * `:not_a_value_module` – something that is neither a module built with
      `Ambient.Value` nor a table atom
      was passed to `Ambient.start_servers/1` and friends.
    * `{:server_start_failed, reason}` – the supervisor refused to start a
      table's server.
  """

  @type reason ::
          :overrides_disabled
          | :server_not_started
          | {:not_shared_owner, pid()}
          | :cant_allow_in_shared_mode
          | :not_a_value_module
          | {:server_start_failed, term()}

  defexception [:reason, :table, :message]

  @type t :: %__MODULE__{reason: reason(), table: atom() | nil, message: String.t()}

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    table = Keyword.get(opts, :table)

    %__MODULE__{reason: reason, table: table, message: format(reason, table)}
  end

  defp format(:overrides_disabled, table) do
    "Ambient overrides are disabled in this build#{about(table)}. Set " <>
      "`config :ambient, enable_overrides: config_env() != :prod` and recompile. " <>
      "The flag defaults to false so a release can never carry the override machinery."
  end

  defp format(:server_not_started, table) do
    "no Ambient override server for #{inspect(table)}; call " <>
      "Ambient.start_servers/1 before writing overrides (test-only)."
  end

  defp format({:not_shared_owner, owner}, table) do
    "#{inspect(table)} is in shared mode, owned by #{inspect(owner)}; only that " <>
      "process may write to it. Call Ambient.set_private/1 to go back to " <>
      "process-scoped overrides."
  end

  defp format(:cant_allow_in_shared_mode, table) do
    "#{inspect(table)} is in shared mode, so every process already reads the " <>
      "shared owner's values – allow/3 has nothing to grant. Call " <>
      "Ambient.set_private/1 first if you meant to scope overrides per process."
  end

  defp format(:not_a_value_module, table) do
    "#{inspect(table)} is not a valid Ambient value module – pass a loaded module " <>
      "exporting __ambient_table__/0 (e.g. Ambient.Clock, or a `use Ambient.Config` " <>
      "module), or a raw table atom like :my_overrides."
  end

  defp format({:server_start_failed, reason}, table) do
    "Ambient could not start a server for #{inspect(table)}: #{inspect(reason)}"
  end

  defp about(nil), do: ""
  defp about(table), do: ", so #{inspect(table)} cannot be written"
end
