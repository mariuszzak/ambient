defmodule Ambient.TestHelpers do
  @moduledoc false
  # Shared across test files. The Server handles `:DOWN` asynchronously, so
  # cleanup assertions have to poll rather than assume.

  @doc "Poll `fun` until it returns truthy, or give up. Returns what it last saw."
  @spec eventually((-> as_boolean(term())), non_neg_integer()) :: as_boolean(term())
  def eventually(fun, retries \\ 200)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, retries) do
    if result = fun.() do
      result
    else
      Process.sleep(5)
      eventually(fun, retries - 1)
    end
  end
end
