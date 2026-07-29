defmodule Ambient.FacadeTest do
  use ExUnit.Case, async: true

  # A target with a couple of public functions, a default arg, and a
  # double-underscore function that must never be re-exported.
  defmodule Target do
    def double(n), do: n * 2
    def greet(name, greeting \\ "hi"), do: "#{greeting}, #{name}"
    def secret, do: :nope
    def __private_helper__, do: :nope
    def __ambient_table__, do: :target_table
  end

  defmodule ArityFacade do
    use Ambient.Facade, for: Ambient.FacadeTest.Target, except: [{:greet, 1}]
  end

  defmodule FullFacade do
    use Ambient.Facade, for: Ambient.FacadeTest.Target
  end

  defmodule FilteredFacade do
    use Ambient.Facade, for: Ambient.FacadeTest.Target, except: [:secret, {:greet, 3}]
  end

  defmodule OnlyFacade do
    use Ambient.Facade, for: Ambient.FacadeTest.Target, only: [:double]
  end

  defmodule OnlyExceptFacade do
    use Ambient.Facade, for: Ambient.FacadeTest.Target, only: [:double, :greet], except: [:double]
  end

  test "delegates public functions to the target" do
    assert FullFacade.double(21) == 42
    assert FullFacade.greet("sam") == "hi, sam"
    assert FullFacade.greet("sam", "yo") == "yo, sam"
  end

  test "delegates every exported arity of a defaulted function" do
    exported = FullFacade.__info__(:functions)
    assert {:greet, 1} in exported
    assert {:greet, 2} in exported
  end

  test "never re-exports __-prefixed functions" do
    refute function_exported?(FullFacade, :__private_helper__, 0)
  end

  test "passes __ambient_table__/0 through, so the facade can be registered" do
    # The one deliberate exception to the __-prefix rule: without it
    # Ambient.start_servers/1 and set_shared/2 reject a facade.
    assert FullFacade.__ambient_table__() == :target_table
    assert OnlyFacade.__ambient_table__() == :target_table, ":only must not filter it out"
  end

  test ":except skips by name" do
    refute function_exported?(FilteredFacade, :secret, 0)
    # {:greet, 3} isn't a real arity, so both greet clauses survive
    assert function_exported?(FilteredFacade, :greet, 1)
    assert function_exported?(FilteredFacade, :greet, 2)
  end

  test ":except skips a single arity of a defaulted function" do
    refute function_exported?(ArityFacade, :greet, 1)
    assert function_exported?(ArityFacade, :greet, 2)
    assert ArityFacade.greet("sam", "yo") == "yo, sam"
  end

  test ":only restricts to the listed functions" do
    assert OnlyFacade.double(3) == 6
    refute function_exported?(OnlyFacade, :greet, 1)
    refute function_exported?(OnlyFacade, :secret, 0)
  end

  test ":except is applied after :only" do
    refute function_exported?(OnlyExceptFacade, :double, 1)
    assert function_exported?(OnlyExceptFacade, :greet, 1)
  end
end
