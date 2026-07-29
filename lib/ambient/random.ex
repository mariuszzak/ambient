defmodule Ambient.Random do
  @moduledoc """
  A process-overridable, seedable pseudo-random number generator.

  In production the wrapper falls through to Erlang's `:rand`. In tests,
  `seed/1` pins a deterministic state in the calling process; subsequent calls
  walk the same byte-precise stream every run – so a flake-prone path (jittered
  backoff, a shuffled queue, an A/B tiebreaker) can be asserted exactly instead
  of retried.

  ## Inheritance

  The seed lives in `Ambient.ProcessOverride`, so any child process spawned by
  the test inherits it through:

    * the implicit `$callers` chain (`Task.async/1`, `Agent.start/1` – no setup
      needed), and
    * explicit `Ambient.Random.allow/1` for long-lived processes.

  Note: each process draws from a **fork** of the seeded stream, not one shared
  advancing stream. A child inherits the owner's state *as of the seed* and
  advances its own private copy, so the owner and a freshly-spawned child (or
  two sibling tasks) that each draw will produce the *same* sequence. This keeps
  results deterministic per process; it does not interleave draws across
  processes into one global sequence.

  ## Production

      Ambient.Random.uniform(100)        # 1..100
      Ambient.Random.shuffle(cards)
      Ambient.Random.take_random(deck, 5)

  ## Tests

      Ambient.Random.seed(42)
      x = Ambient.Random.uniform(100)    # same value every run
      Ambient.Random.reset()

  ## Cryptography

  Seedable and unpredictable are opposites: a stream reproducible from a
  64-bit integer cannot be credential-grade, and `:exsss` leaks its internal
  state to anyone who sees a handful of outputs. The split is therefore
  per-function:

    * `bytes/1` – **credential-safe in production.** With no seed in scope it
      is `:crypto.strong_rand_bytes/1`, and production builds don't compile the
      override machinery in (`Ambient.ProcessOverride.enabled?/0`), so no
      ambient context can downgrade it. Under `seed/1`, in a test build, it is
      deterministic and *not* safe.
    * `uniform/0,1`, `normal/2`, `shuffle/1`, `random/1`, `take_random/2` –
      `:rand`-backed, **never** credential-grade in any build. Don't hand-roll
      a token out of `uniform(256)`.

  `Ambient.Credo.NoDirectRandom` keeps direct `:rand` / `Enum.shuffle` calls
  from creeping back in.
  """

  use Ambient.Value, table: :ambient_random_overrides

  @key :rng_state

  # Read the seeded state, run `stateful` against it and store the advanced
  # state back – or, with no seed in scope, evaluate `stateless`.
  #
  # A macro rather than a function so the whole seeded branch disappears in a
  # build without overrides, leaving a direct `:rand.*` call. `stateless` also
  # matters in *enabled* builds: the previous fall-through built a fresh
  # `:rand.seed_s(:exsss)` on every call, which is ~12x the cost of the plain
  # `:rand` function that seeds the process dictionary once, lazily.
  defmacrop with_state(stateful, stateless) do
    if @ambient_enabled do
      quote do
        case Ambient.ProcessOverride.get_and_update(@ambient_table, @key, unquote(stateful)) do
          {:ok, value} -> value
          :error -> unquote(stateless)
        end
      end
    else
      stateless
    end
  end

  @doc """
  Pin the per-process RNG to a deterministic stream derived from `seed`.
  Inherited by child processes via the `$callers` chain.
  """
  if @ambient_enabled do
    @spec seed(integer()) :: :ok
  else
    @spec seed(integer()) :: no_return()
  end

  def seed(seed) when is_integer(seed) do
    put_override(@key, :rand.seed_s(:exsss, {seed, seed, seed}))
  end

  @doc "Drop the per-process seed; subsequent calls use real randomness."
  @spec reset() :: :ok
  def reset do
    delete_override(@key)
  end

  @doc "Whether a seed is currently in effect for this process."
  @spec seeded?() :: boolean()
  def seeded?, do: overridden?(@key)

  @doc "Random float in `[0.0, 1.0)`. Mirrors `:rand.uniform_s/1`."
  @spec uniform() :: float()
  def uniform, do: with_state(&:rand.uniform_s/1, :rand.uniform())

  @doc """
  Random integer in `1..n`. Mirrors `:rand.uniform_s/2`. Raises when `n < 1`.
  """
  @spec uniform(pos_integer()) :: pos_integer()
  def uniform(n) when is_integer(n) and n >= 1 do
    with_state(fn s -> :rand.uniform_s(n, s) end, :rand.uniform(n))
  end

  @doc """
  Random float from a normal distribution. Mirrors `:rand.normal_s/3`, so the
  second argument is the **variance** (σ²), not the standard deviation –
  `normal(0, 9)` has σ = 3.
  """
  @spec normal(number(), number()) :: float()
  def normal(mean, variance) do
    with_state(fn s -> :rand.normal_s(mean, variance, s) end, :rand.normal(mean, variance))
  end

  @doc "Shuffle an enumerable. Seed-respecting drop-in for `Enum.shuffle/1`."
  @spec shuffle(Enumerable.t()) :: list()
  def shuffle(enum) do
    list = Enum.to_list(enum)
    with_state(fn s -> do_shuffle(list, s) end, Enum.shuffle(list))
  end

  @doc "Pick one element at random. Seed-respecting drop-in for `Enum.random/1`."
  @spec random(Enumerable.t()) :: any()
  def random(enum) do
    case Enum.to_list(enum) do
      [] -> raise Enum.EmptyError
      list -> Enum.at(list, uniform(length(list)) - 1)
    end
  end

  @doc """
  Take `n` random elements without replacement. Seed-respecting drop-in for
  `Enum.take_random/2`.
  """
  @spec take_random(Enumerable.t(), non_neg_integer()) :: list()
  def take_random(enum, n) when is_integer(n) and n >= 0 do
    Enum.take(shuffle(enum), n)
  end

  @doc """
  Return `n` random bytes.

  With no seed in scope this is `:crypto.strong_rand_bytes/1` – so it is safe
  for credential material in production, where the override machinery isn't
  compiled in at all (see `Ambient.ProcessOverride.enabled?/0`) and this is the
  only reachable clause.

  Under `seed/1` it instead draws from the deterministic, **non-cryptographic**
  stream, so a test can assert an exact token. That path exists only in builds
  that opted into overrides.

  Unlike the other functions here, `bytes/1` therefore does *not* fall through
  to `:rand`.
  """
  @spec bytes(non_neg_integer()) :: binary()
  def bytes(n) when is_integer(n) and n >= 0 do
    with_state(fn s -> seeded_bytes(n, s, <<>>) end, :crypto.strong_rand_bytes(n))
  end

  if @ambient_enabled do
    defp seeded_bytes(0, state, acc), do: {acc, state}

    defp seeded_bytes(n, state, acc) do
      {byte, state} = :rand.uniform_s(256, state)
      seeded_bytes(n - 1, state, <<acc::binary, byte - 1>>)
    end
  end

  if @ambient_enabled do
    # Fisher–Yates-style shuffle backed by the seeded state so output is
    # reproducible under `seed/1`. Only reachable from the seeded branch, so it
    # doesn't exist in a build without overrides.
    defp do_shuffle(list, state) do
      {tagged, state} =
        Enum.map_reduce(list, state, fn x, s ->
          {tag, s} = :rand.uniform_s(s)
          {{tag, x}, s}
        end)

      sorted = tagged |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
      {sorted, state}
    end
  end
end
