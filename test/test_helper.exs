# Credo ships as `runtime: false`, so its services (used by `Credo.Test.Case`
# to exercise the bundled checks) aren't started automatically – start them here,
# unless a prior task in the same VM (e.g. `mix credo` under the `check` alias)
# already did.
if is_nil(Process.whereis(Credo.Service.SourceFileAST)) do
  {:ok, _} = Application.ensure_all_started(:credo)
end

Ambient.start_servers([
  Ambient.Clock,
  Ambient.TestConfig,
  :ambient_core_test
])

ExUnit.start()
