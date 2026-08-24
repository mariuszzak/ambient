defmodule Ambient.TestCounter do
  @moduledoc false
  # A value whose *read* writes: `next/0` returns the current count and stores
  # the next one. No built-in value has that shape, and it is the one that
  # makes shared mode interesting – every process reads and writes the same
  # row, so a plain fetch-then-put loses updates under concurrency.
  use Ambient.Value, table: :ambient_counter_overrides

  def start(n), do: put_override(:counter, n)

  def next do
    case Ambient.ProcessOverride.get_and_update(@ambient_table, :counter, &{&1, &1 + 1}) do
      {:ok, value} -> value
      :error -> :no_counter
    end
  end
end
