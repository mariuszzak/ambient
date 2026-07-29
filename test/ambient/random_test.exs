defmodule Ambient.RandomTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ambient.Random

  describe "determinism" do
    test "the same seed replays the same sequence" do
      Random.seed(42)
      a = for _ <- 1..20, do: Random.uniform(1000)
      Random.reset()
      Random.seed(42)
      b = for _ <- 1..20, do: Random.uniform(1000)
      assert a == b
    end

    test "different seeds (almost surely) differ" do
      Random.seed(1)
      a = for _ <- 1..20, do: Random.uniform(1_000_000)
      Random.seed(2)
      b = for _ <- 1..20, do: Random.uniform(1_000_000)
      refute a == b
    end

    property "any seed replays identically" do
      check all(seed <- integer(), n <- integer(1..1000), len <- integer(1..30)) do
        Random.seed(seed)
        first = for _ <- 1..len, do: Random.uniform(n)
        Random.seed(seed)
        second = for _ <- 1..len, do: Random.uniform(n)
        assert first == second
      end
    end
  end

  describe "ranges + shapes" do
    test "uniform/1 stays within 1..n" do
      Random.seed(7)

      for _ <- 1..500 do
        v = Random.uniform(10)
        assert v in 1..10
      end
    end

    test "uniform/0 is in [0.0, 1.0)" do
      Random.seed(7)
      v = Random.uniform()
      assert is_float(v) and v >= 0.0 and v < 1.0
    end

    test "uniform/1 raises for n < 1" do
      assert_raise FunctionClauseError, fn -> Random.uniform(0) end
    end

    test "normal/2 returns a float and is deterministic under a seed" do
      Random.seed(7)
      a = Random.normal(0.0, 1.0)
      Random.seed(7)
      assert Random.normal(0.0, 1.0) == a
      assert is_float(a)
    end

    test "uniform(1) is always 1" do
      Random.seed(7)
      assert Enum.all?(1..50, fn _ -> Random.uniform(1) == 1 end)
    end

    test "seed(0) is accepted and deterministic" do
      Random.seed(0)
      a = Random.uniform(1000)
      Random.seed(0)
      assert Random.uniform(1000) == a
    end
  end

  describe "boundary inputs" do
    test "shuffle/1 of an empty enumerable is []" do
      Random.seed(1)
      assert Random.shuffle([]) == []
    end

    test "take_random/2 with 0 is [], and n > length returns all" do
      Random.seed(1)
      assert Random.take_random([:a, :b, :c], 0) == []
      assert Enum.sort(Random.take_random([:a, :b, :c], 99)) == [:a, :b, :c]
    end

    test "bytes(0) is an empty binary" do
      Random.seed(1)
      assert Random.bytes(0) == <<>>
    end
  end

  describe "collection helpers" do
    test "shuffle/1 is a deterministic permutation under a seed" do
      input = Enum.to_list(1..10)
      Random.seed(123)
      a = Random.shuffle(input)
      Random.seed(123)
      b = Random.shuffle(input)
      assert a == b
      assert Enum.sort(a) == input
    end

    test "take_random/2 returns n distinct members" do
      Random.seed(5)
      picked = Random.take_random(1..100, 5)
      assert length(picked) == 5
      assert Enum.uniq(picked) == picked
      assert Enum.all?(picked, &(&1 in 1..100))
    end

    test "random/1 picks a member and raises on empty" do
      Random.seed(5)
      assert Random.random(1..3) in 1..3
      assert_raise Enum.EmptyError, fn -> Random.random([]) end
    end

    test "bytes/1 returns n bytes, deterministic under a seed" do
      Random.seed(9)
      a = Random.bytes(16)
      Random.seed(9)
      b = Random.bytes(16)
      assert byte_size(a) == 16
      assert a == b
    end

    test "bytes/1 advances the seeded stream rather than repeating itself" do
      Random.seed(9)
      assert Random.bytes(16) != Random.bytes(16)
    end

    test "bytes/1 draws from the same stream as uniform/1 – golden vector" do
      # Pinned so a refactor of the seeded path can't silently change the byte
      # stream under consumers who assert on exact fixtures.
      Random.seed(42)
      assert Base.encode16(Random.bytes(16)) == "FB16C340F26FF15CB6131FEF2E17E251"
    end

    test "bytes/1 is inherited through $callers, like the rest" do
      Random.seed(3)
      from_child = Task.async(fn -> Random.bytes(8) end) |> Task.await()
      # The child forks the stream as of the seed, so re-seeding reproduces it.
      Random.seed(3)
      assert Random.bytes(8) == from_child
    end
  end

  describe "without a seed (the production fall-through)" do
    test "delegate to the process-dictionary :rand state, not a fresh seed per call" do
      # Regression: the fall-through built `:rand.seed_s(:exsss)` on every call
      # – ~12x the cost of plain :rand, which seeds the dictionary once. Assert
      # on the dictionary itself; range/shape checks passed under the old code
      # too, so they could never have caught this.
      refute Random.seeded?()

      Task.async(fn ->
        assert :rand.export_seed() == :undefined

        Random.uniform(1000)
        after_first = :rand.export_seed()
        assert after_first != :undefined, "should have seeded the process dictionary"

        Random.uniform(1000)
        assert :rand.export_seed() != after_first, "should advance that state, not replace it"
      end)
      |> Task.await()
    end

    test "every unseeded function shapes correctly and advances" do
      assert Random.uniform() >= 0.0 and Random.uniform() < 1.0
      assert Random.uniform(10) in 1..10
      assert is_float(Random.normal(0, 1))
      assert Enum.sort(Random.shuffle([1, 2, 3])) == [1, 2, 3]
      assert length(Random.take_random(1..100, 5)) == 5
      assert Random.random(1..3) in 1..3

      draws = for _ <- 1..50, do: Random.uniform(1_000_000)
      assert length(Enum.uniq(draws)) > 1
    end
  end

  describe "bytes/1 without a seed" do
    # The production clause. In a build without overrides compiled in it is the
    # *only* clause – see test/fixtures/disabled_build_check.exs.
    test "falls through to :crypto.strong_rand_bytes/1" do
      assert byte_size(Random.bytes(32)) == 32
      assert Random.bytes(32) != Random.bytes(32)
    end
  end

  describe "reset + inheritance" do
    test "reset/0 falls back to real randomness (values still valid)" do
      Random.seed(1)
      Random.reset()
      assert Random.uniform(10) in 1..10
    end

    test "a Task inherits the seeded stream" do
      Random.seed(77)
      expected = Random.uniform(10_000)
      Random.seed(77)
      task = Task.async(fn -> Random.uniform(10_000) end)
      assert Task.await(task) == expected
    end

    test "allow/1 shares the seed with an Agent" do
      Random.seed(55)
      {:ok, agent} = Agent.start(fn -> nil end)
      Random.allow(agent)
      via_agent = Agent.get(agent, fn _ -> Random.uniform(10_000) end)
      Random.seed(55)
      assert via_agent == Random.uniform(10_000)
    end
  end
end
