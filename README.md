# Ambient

Process-scoped value overrides for Elixir. A test sets a value – a config
entry, the current time, a random seed, an env var – and that value applies to
its process **and everything that process spawns**, never to a concurrent test,
and is cleaned up when the test exits. In production the override machinery
isn't compiled in at all.

The clearest case is config. `Application.put_env/3` is VM-global, so a test
that overrides a setting can't be `async: true`:

```elixir
use ExUnit.Case, async: true

test "gives up after the configured number of retries" do
  MyApp.Config.put(:retry_limit, 1)

  assert {:error, :exhausted} = Billing.charge(invoice)
end

test "a concurrent test is unaffected" do
  assert MyApp.Config.get(:retry_limit, 3) == 3
end
```

No `setup`/`on_exit` pairing, no restoring the old value, no `async: false`.
The same mechanism backs a frozen [clock](#clock), a seeded
[RNG](#random), overridable [env vars](#env), and
[any ambient value of your own](#build-your-own).

- [Why](#why)
- [Should you use this?](#should-you-use-this)
- [How it works](#how-it-works)
- [Install](#install)
- [Wrap it in your own namespace](#wrap-it-in-your-own-namespace)
- [Built-in values](#built-in-values) – [Config](#config), [Clock](#clock), [Random](#random), [Env](#env)
- [Reaching a process you didn't spawn](#reaching-a-process-you-didnt-spawn)
- [Shared mode](#shared-mode-for-async-false-tests)
- [Build your own](#build-your-own)
- [The compile-time switch and production cost](#the-compile-time-switch-and-production-cost)
- [Credo checks](#enforcing-the-conventions-optional-credo-checks)
- [Errors](#errors)
- [How it compares](#how-it-compares)

## Why

You don't need a library to fake a clock. Write one – it's a dozen lines:

```elixir
defmodule MyApp.Clock.Fake do
  def utc_now do
    case Process.get(:fake_now) do
      nil -> DateTime.utc_now()
      now -> now
    end
  end

  def set(now), do: Process.put(:fake_now, now)
end
```

Pick between that and the real one with `Application.compile_env/3` and you
have dependency injection: per-test isolated, `async: true`-safe, cleans itself
up when the test process dies, no dependency at all. **If that's enough for
your suite, use it.**

Better still, pass the value:

```elixir
now = MyApp.Clock.utc_now()
Task.async(fn -> Billing.charge(invoice, now) end)
```

Closures capture, so an argument crosses process boundaries perfectly well. If
you can thread it – or your app already threads a context struct – do that. A
parameter beats an ambient read every time.

This library is for the reads where there is no parameter to pass:

**The call site isn't yours.** Ecto generates timestamps from an MFA:

```elixir
@timestamps_opts [autogenerate: {MyApp.Clock, :naive_utc_now, []}]
```

Ecto invokes that at insert time, with the arguments it chose. Same shape for
changeset autogeneration, Phoenix plugs, Absinthe middleware, telemetry
handlers.

**The consumer is stdlib.** `Enum.shuffle/1` and `Enum.random/1` read `:rand`'s
per-process state. Threading an RNG means `{value, rng} = next(rng)` at every
call site – the tax Elixir deliberately doesn't pay.

**The process isn't in your spawn tree.** A GenServer started by the app
supervisor and ticking on `handle_info(:tick)`; a LiveView Phoenix spawned; a
live Oban queue in an integration test. No closure to capture into.

For those, the fake needs per-test state that is reachable without a parameter
– and the obvious places give you one property or the other, never both:

| Where the value lives | Isolated per test | Reachable from another process |
|---|---|---|
| compile-time DI (`@clock` attribute) | ❌ one implementation per build | ✅ needs no parameter |
| a threaded value or fake | ✅ | ❌ needs a parameter at every hop |
| `Process.put/2` | ✅ | ❌ lost at the boundary |
| `Application.put_env/3`, `System.put_env/2` | ❌ VM-global | ✅ |
| **ETS keyed by owner + `$callers` + monitors** | ✅ | ✅ |

Only the last row gets both, and it isn't a novel idea:
`Ecto.Adapters.SQL.Sandbox` is exactly this, for database connections.
Threading a `conn` through every function is possible and nobody does it – the
connection is ambient, so Ecto pays for an ownership mechanism instead.

**Ambient is that fake, minus the wiring.** No behaviour, no second module, no
config wiring, no injection point to thread – and in a production build the
machinery isn't compiled in, so the fake never ships.

For `Application.get_env/3` and `System.get_env/1` there isn't even a fake to
write. Those are keyed lookups, not a contract you can swap: a per-test config
layer *is* an ownership problem, which is why it's the example at the top of
this page.

## Should you use this?

**Don't bother if:**

- **Your tests don't spawn.** The twelve-line `Process.put` fake above is
  enough and costs you nothing.
- **You can pass the value.** Do that instead.
- **You're comfortable patching modules.** [Repatch](https://hexdocs.pm/repatch)
  and [Mimic](https://hexdocs.pm/mimic) reach `DateTime`, `System`,
  `Application` and `:rand` directly – no wrapper, no call-site change, no
  production dependency, same per-process ownership model. Lower adoption cost
  than this library. See [How it compares](#how-it-compares).

**Reach for it if:**

- **`Application.put_env/3` is why part of your suite is `async: false`.** This
  is the strongest case, because it's the one with no cheaper answer: there's
  no fake to write, and patching `Application.get_env/3` means hand-writing a
  fallthrough clause per key. `MyApp.Config.put(:key, value)` is the whole API.
- **You want finished values, not a patching primitive.** `Clock.advance(hours:
  1, minutes: 30)` folds summed units; `Env.unset/1` distinguishes "overridden
  to absent" from "no override"; `Random` keeps a seeded stream that survives
  `$callers` and stays atomic under shared mode. With a patching library you
  rebuild each of those yourself, per value.
- **You want the seam explicit.** The wrapper is real API: greppable,
  documented, [enforceable by Credo](#enforcing-the-conventions-optional-credo-checks),
  and no module you don't own gets rewritten.
- **You want the test seam provably absent from the release.** That's what lets
  `Ambient.Random.bytes/1` be `:crypto.strong_rand_bytes/1` in production and
  seeded in tests – see
  [the compile-time switch](#the-compile-time-switch-and-production-cost).
- **You have ambient values of your own** – current tenant, acting user,
  request id. [`use Ambient.Value`](#build-your-own) gives them the same
  machinery in about ten lines each.

Condensed comparison – the [full version](#how-it-compares) is at the bottom:

| | Ambient | Repatch / Mimic | Mox | put_env |
|---|---|---|---|---|
| Call sites change | yes | no | yes | no |
| `async: true` safe | ✅ | ✅ | ✅ | ❌ |
| Reaches a dependency's internals | ❌ | ✅ | ❌ | ➖ its config reads only |
| Keyed config/env overrides | first-class | per-key fallthrough clause | awkward | global |
| Rewrites modules you don't own | no | yes | no | no |

**Two things Ambient doesn't do.** It can't touch a dependency that calls
`DateTime.utc_now/0` in its own internals – Ambient only redirects reads that
go through an Ambient wrapper, and you can't add a wrapper to code you don't
own. And there's no `verify_on_exit!`: forget `Clock.set/1` and the test
quietly reads the real clock instead of failing loudly the way an unstubbed
Mox call would.

## How it works

Each override domain is a named, public ETS table owned by an
`Ambient.ProcessOverride.Server`. Writes are keyed `{owner_pid, key}`; reads
resolve through **self → allow chain → `$callers`**, or straight to the shared
owner when the table is shared. The server monitors every writer and clears its
rows (and any `allow` rows pointing at it) on exit – so concurrent `async: true`
tests never see each other's values and nothing leaks.

Reads are plain ETS lookups in the calling process: no GenServer call, no
serialization point between concurrent tests.

## Install

```elixir
def deps do
  [{:ambient, "~> 0.1"}]
end
```

Not a test-only dependency: you read through `MyApp.Clock` and `MyApp.Config`
from application code. The override machinery is what's absent from production,
not the library.

Opt in, in `config/config.exs`:

```elixir
config :ambient, enable_overrides: config_env() != :prod
```

It defaults to `false`, so a build that doesn't set it – your release – has no
override machinery compiled in at all. Gate on `!= :prod` rather than
`== :test`: `:prod` is the only env where the guarantee matters, and Dialyzer
runs in `:dev`.

Then [wrap the values you'll use](#wrap-it-in-your-own-namespace) and start one
override server per table before the suite runs, in `test/test_helper.exs`:

```elixir
Ambient.start_servers([MyApp.Clock, MyApp.Random, MyApp.Env, MyApp.Config])
ExUnit.start()
```

Forgetting the config line fails loudly at `Ambient.start_servers/1`; forgetting
a table surfaces at the first write to it, as `:server_not_started`. That's also
what you'll hit trying to set an override in `iex -S mix`, where nothing has
started the servers – call `Ambient.start_servers/1` there too.

## Wrap it in your own namespace

Adopting Ambient otherwise means a third-party module name at every clock,
config and env read in your application code – and backing out would mean
touching all of them. So define your own module per value and call that
everywhere. The dependency is then named in exactly four modules of your
application code:

```elixir
defmodule MyApp.Clock do
  use Ambient.Facade, for: Ambient.Clock
end

defmodule MyApp.Random do
  use Ambient.Facade, for: Ambient.Random
end

defmodule MyApp.Env do
  use Ambient.Facade, for: Ambient.Env
end

defmodule MyApp.Config do
  use Ambient.Config, otp_app: :my_app
end
```

The delegates are derived at compile time, so a wrapper never drifts when the
wrapped module gains a function, and `Ambient.start_servers/1`, `set_shared/2`
and `set_private/1` all accept your wrapper rather than the module behind it.

Narrow the surface with `:only` / `:except` (names or `{name, arity}` pairs):

```elixir
use Ambient.Facade, for: Ambient.Clock, only: [:utc_now, :utc_today]
use Ambient.Facade, for: Ambient.Random, except: [:normal]
```

The rest of this README uses `MyApp.*` on that assumption. Calling
`Ambient.Clock` directly works identically – you just spread the dependency
across your call sites.

## Built-in values

Four ready-made ambient values. Each is a thin wrapper you call from
application code instead of the global it replaces, plus test-only setters
scoped to the calling process and everything it spawns.

### Config

Bind an accessor to your OTP app once:

```elixir
defmodule MyApp.Config do
  use Ambient.Config, otp_app: :my_app
end
```

Then read through it everywhere you would have called `Application.get_env/3`:

```elixir
# lib/my_app/billing.ex
def retry_limit, do: MyApp.Config.get(:retry_limit, 3)
def dunning_enabled?, do: MyApp.Config.get(:dunning_enabled, false)
```

`get/2` checks for a process-local override first and falls back to
`Application.get_env(:my_app, key, default)`. In a production build the lookup
isn't compiled in at all – `get/2` *is* `Application.get_env/3`.

The [example at the top of this page](#ambient) is the basic case: two
`async: true` tests, one overriding, the other unaffected. The override dies
with the test process. It reaches spawned work too – a `Task` your code starts
inherits it through `$callers` with no setup:

```elixir
test "the background charge sees the override" do
  MyApp.Config.put(:retry_limit, 1)

  assert Task.async(fn -> Billing.charge(invoice) end) |> Task.await() ==
           {:error, :exhausted}
end
```

For a long-lived process the test didn't spawn – a supervised GenServer, a
LiveView – grant it access explicitly (see
[Reaching a process you didn't spawn](#reaching-a-process-you-didnt-spawn)):

```elixir
MyApp.Config.allow(genserver_pid)
```

The surface you'll use:

```elixir
MyApp.Config.get(:key, default)     # read: override, else Application.get_env/3
MyApp.Config.put(:key, value)       # override for this process and its children
                                    # (put_override/2 is the same function)
MyApp.Config.revert(:key)           # drop one override, back to app env
MyApp.Config.reset()                # drop every override this process set
MyApp.Config.overridden?(:key)      # is one in scope?
MyApp.Config.allow(pid)             # let another process read this one's overrides
```

Bind as many accessors as you have apps – each `otp_app` gets its own table, so
an umbrella's apps never collide.

### Clock

Wraps `Ambient.Clock`. Read time through it and a test can freeze time, or
travel, without `Process.sleep/1` or hand-rolled date arithmetic:

```elixir
# app code – instead of DateTime.utc_now/0, Date.utc_today/0, …
MyApp.Clock.utc_now()
MyApp.Clock.utc_today()
MyApp.Clock.naive_utc_now()
MyApp.Clock.now("Europe/Warsaw")   # needs a configured time zone database

# tests
MyApp.Clock.set(~U[2026-01-01 09:00:00Z])
MyApp.Clock.advance(days: 1)     # also :hours, :minutes, :seconds, or a bare int
MyApp.Clock.advance(hours: 1, minutes: 30)   # units are summed
MyApp.Clock.advance(-90)         # backwards, in seconds
MyApp.Clock.reset()
```

```elixir
test "a token expires after 24 hours" do
  MyApp.Clock.set(~U[2026-01-01 09:00:00Z])
  token = Tokens.issue(user)

  MyApp.Clock.advance(hours: 23)
  assert Tokens.valid?(token)

  MyApp.Clock.advance(hours: 2)
  refute Tokens.valid?(token)
end
```

`set/1` and `advance/1` return the new time, so they compose into assertions.

### Random

Wraps `Ambient.Random`.

```elixir
# app code
MyApp.Random.uniform(100)        # 1..100
MyApp.Random.uniform()           # float in [0.0, 1.0)
MyApp.Random.normal(0.0, 9.0)    # mean, *variance* – σ = 3, as :rand.normal_s/3
MyApp.Random.shuffle(cards)
MyApp.Random.take_random(deck, 5)
MyApp.Random.bytes(32)

# tests – same seed replays the same stream every run
MyApp.Random.seed(42)
first = MyApp.Random.uniform(100)
MyApp.Random.seed(42)
assert MyApp.Random.uniform(100) == first
```

Repeated calls in one process advance the stream, so four `shuffle/1` calls
give four different permutations – the same four every run.

Across processes it's a **fork**, not one shared stream: a child inherits the
owner's state as of the seed and advances its own copy. Sequential work is
unsurprising, but **concurrent siblings each get the same values**:

```elixir
MyApp.Random.seed(42)
1..4 |> Enum.map(fn _ -> Task.async(fn -> MyApp.Random.bytes(4) end) end)
     |> Task.await_many()
#=> four identical tokens
```

That is deliberate, and it's the only way to be reproducible: which sibling
gets which value from a single stream depends on scheduling, so *distinct* and
*reproducible* cannot both hold across concurrent processes. Pick one:

| You want | Use | Cost |
|---|---|---|
| Reproducible run to run | `seed/1` (default) | concurrent siblings share values |
| Distinct values everywhere | `seed/1` + [shared mode](#shared-mode-for-async-false-tests) | ordering isn't reproducible; `async: false` |
| Distinct *and* reproducible per worker | `seed/1` inside each worker, with its own seed | you choose the seeds |

#### Cryptography

Seedable and unpredictable are opposites, so the rule is per-function, not
per-module:

| | No seed in scope | Under `seed/1` |
|---|---|---|
| `bytes/1` | `:crypto.strong_rand_bytes/1` – **credential-safe** | deterministic, not safe |
| `uniform`, `normal`, `shuffle`, `random`, `take_random` | `:rand` (`exsss`) – **never** credential-grade | deterministic |

```elixir
# fine – strong in production, replayable in tests
MyApp.Random.bytes(32) |> Base.url_encode64(padding: false)

# never – a token is not a dice roll
Enum.map(1..32, fn _ -> MyApp.Random.uniform(256) end)
```

The right-hand column can't exist in a production build: the seeded clause isn't
compiled at all, so no `$callers` chain, `allow/3` grant, seeds script or remote
console can reach it. That holds as long as you derive the flag from
`config_env/0` – see
[the compile-time switch](#the-compile-time-switch-and-production-cost).

### Env

Wraps `Ambient.Env`.

```elixir
# app code – instead of System.get_env/1
MyApp.Env.get("DATABASE_URL")
MyApp.Env.get("PORT", "4000")
MyApp.Env.fetch!("SECRET_KEY_BASE")

# tests
MyApp.Env.put("FEATURE_X", "true")
MyApp.Env.put_all(%{"REGION" => "eu-west-1", "TIER" => "premium"})
MyApp.Env.unset("HOME")      # override it as absent, even though it really is set
MyApp.Env.revert("HOME")     # drop the override, see the real value again
MyApp.Env.reset()            # drop every override this process set
```

`unset/1` and `revert/1` are deliberately different: `unset/1` *writes* an
override meaning "absent", which is how you test that path for a variable that
really is set; `revert/1` removes an override.

> **Runtime reads only – and that limits this one.** An override affects a read
> only while it is in scope. Anything resolved at boot (`config/runtime.exs`) or
> at compile time has already been read. Since idiomatic Elixir reads env vars
> in `runtime.exs` and puts them into app config, [`Config`](#config) is usually
> the value you want; `Env` is for the reads that genuinely happen at runtime.

## Reaching a process you didn't spawn

Plain `Task.async`/`Agent` children inherit automatically via `$callers`. For a
long-lived process the test didn't spawn – a supervised GenServer, a LiveView –
authorise it explicitly, the same pattern as `Ecto.Adapters.SQL.Sandbox.allow/3`:

```elixir
setup do
  pid = start_supervised!(MyApp.Scheduler)

  MyApp.Clock.set(~U[2026-01-01 09:00:00Z])
  MyApp.Clock.allow(pid)      # now the scheduler reads the test's clock

  %{scheduler: pid}
end
```

Every value module has it, and it takes any pid you can get hold of – a
`start_supervised!/1` return, `Process.whereis/1` for a named server, a
LiveView's `view.pid`:

```elixir
MyApp.Clock.allow(worker_pid)
MyApp.Random.allow(worker_pid)
MyApp.Env.allow(worker_pid)
MyApp.Config.allow(genserver_pid)
```

Grants chain: if A allows B and B allows C, C resolves through to A. Cycles
terminate rather than spinning.

> **Background jobs often don't need this.** Oban's test helpers run the job in
> the calling process – `perform_job/2` invokes `perform/1` directly,
> `testing: :inline` executes "immediately within the calling process", and
> `Oban.drain_queue/2` runs everything in the current process. On those paths a
> worker already sees the test's overrides with no setup. `allow/3` is for a
> live queue in an integration test, where a real producer process runs the job.

## Shared mode (for `async: false` tests)

Sometimes `allow/3` is the wrong tool: the process you need to reach is deep
inside a supervision tree, or you don't have its pid at all.
`Ambient.set_shared/2` makes one process's overrides the ones **every** process
reads:

```elixir
use ExUnit.Case, async: false   # required – this is global state

test "the whole system sees the frozen clock" do
  MyApp.Clock.set(~U[2026-01-01 09:00:00Z])
  Ambient.set_shared(MyApp.Clock)
  on_exit(fn -> Ambient.set_private(MyApp.Clock) end)

  # any process, however spawned, now reads that clock
end
```

`Ambient.start_servers/1`, `set_shared/2` and `set_private/1` all take one
value module (or facade) or a list of them.

Same rule as `Ecto.Adapters.SQL.Sandbox`'s shared mode and `Mox.set_mox_global/0`:
**never in an `async: true` test**, or a concurrent test will see your clock.

While a table is shared:

- only the shared owner may write – `put/3` and `set_shared/2` from anyone else
  raise `{:not_shared_owner, pid}`, so another test can't silently steal the
  table;
- `get_and_update/3` is the deliberate exception, so read-modify-write modules
  keep working atomically from every process – which is what makes
  `Ambient.Random` under shared mode (one globally advancing stream) possible;
- `allow/3` is refused, since every process already reads the owner's values;
- `set_private/1` is deliberately open to any process – it's the way back to a
  sane state, and `on_exit/1` runs in a different process from the test;
- `delete/2` and `reset/0`-style teardown stay scoped to the caller's own rows,
  so a non-owner's `MyApp.Clock.reset()` doesn't (and can't) clear the shared
  value;
- the owner is monitored, so a crashed test drops the table back to private on
  its own rather than leaving the suite globally overridden.

`Ambient.ProcessOverride.mode/1` reports `:private` or `{:shared, pid}`. Unlike
`set_shared/2` and friends it takes a **table**, not a value module, and returns
`:private` for a table it doesn't know – so pass
`MyApp.Clock.__ambient_table__()`, not `MyApp.Clock`.

## Build your own

Nothing about the built-ins is privileged – they're all `use Ambient.Value`.
If your app has an ambient value of its own (the current tenant, the acting
user, a request id), this is the supported way to make it as testable:

```elixir
defmodule MyApp.Tenant do
  use Ambient.Value, table: :my_app_tenant_overrides

  def current, do: get_or(:tenant, MyApp.Tenant.Default)
  def put(tenant), do: put_override(:tenant, tenant)
end

Ambient.start_servers([MyApp.Tenant])   # in test_helper.exs, like a built-in
```

A module wrapping a specific domain usually adds its own verbs on top – a
generated config's `put/2`, `Clock.set/1`, `Random.seed/1`, `Env.put/2` – and
leaves the generic layer below for everything else.

`use Ambient.Value` generates `put_override/2`, `delete_override/1`,
`delete_all/0`, `overridden?/1`, `allow/2`, `set_shared/1`, `set_private/0` and
`__ambient_table__/0` – all `defoverridable` – imports the `get_or/2` macro, and
sets `@ambient_enabled` for the rare hand-rolled branch (see
[the compile-time switch](#the-compile-time-switch-and-production-cost)).

If your reads also *write* (as `Ambient.Random` does, advancing its seed), use
`ProcessOverride.get_and_update/3` rather than a `fetch` + `put` pair – it
resolves, applies your function and writes back atomically, which is what keeps
such a module correct under shared mode. Your function takes the current value
and returns `{result, new_value}`:

```elixir
case ProcessOverride.get_and_update(@table, :counter, &{&1, &1 + 1}) do
  {:ok, previous} -> previous
  :error -> 0          # no override in scope – fall back
end
```

`get_or/2` is a macro on purpose: it expands at compile time, so in a build
without overrides the lookup disappears entirely and only the fallback
expression remains. `def current, do: get_or(:tenant, MyApp.Tenant.Default)`
compiles to `def current, do: MyApp.Tenant.Default`. The fallback is evaluated
only on a miss, so `get_or(:key, expensive_call())` doesn't pay for a call it
doesn't need.

## The compile-time switch and production cost

Every override path is gated on one flag, resolved at compile time via
`Application.compile_env/3`:

```elixir
# config/config.exs
config :ambient, enable_overrides: config_env() != :prod
```

Default `false`. In a build that didn't opt in no override can exist: the ETS
table can't be created, every writer raises, and the override branches aren't
compiled at all. `reset/0`-style teardown stays a safe no-op, so `on_exit`
helpers don't need guarding.

### What it costs in production

Nothing worth measuring. `get_or/2` expands to the fallback expression alone,
so each wrapper compiles to a direct call to the function it wraps:

| Wrapper | Production build compiles to |
|---|---|
| `Ambient.Clock.utc_now/0` | `DateTime.utc_now/0` |
| `Ambient.Random.bytes/1` | `:crypto.strong_rand_bytes/1` |
| `Ambient.Random.uniform/1` | `:rand.uniform/1` |
| `Ambient.Env.get/2` | `System.get_env/2` |
| `MyApp.Config.get/2` | `Application.get_env/3` |

No ETS lookup, no branch, no message round-trip. A
[facade](#wrap-it-in-your-own-namespace) adds one `defdelegate` hop on top –
a direct remote call, not a lookup.

That's the override machinery. Two `Ambient.Random` wrappers do cost something
in their own right, because seed-respecting semantics need a materialized list:
`random/1` is `Enum.to_list/1` plus an index, where `Enum.random/1` samples a
range in constant space, and `take_random/2` shuffles before taking, where
`Enum.take_random/2` samples. On a large enumerable prefer the stdlib function
in code that doesn't need to be reproducible.

### Two gotchas

- **Build releases with `MIX_ENV=prod`.** The flag resolves per `_build` env, so
  a release built with `MIX_ENV=test` carries the machinery. Mix records the
  value in the app manifest, so a release whose runtime config disagrees aborts
  at boot rather than drifting silently.
- **Hard-coding the flag `true` warns** whenever Ambient can tell it's building
  for `:prod` – such a release carries the machinery and `bytes/1` loses its
  guarantee. Derive it from `config_env/0` and the question doesn't arise.

`Ambient.ProcessOverride.enabled?/0` reports the current build.
[Its moduledoc](https://hexdocs.pm/ambient/Ambient.ProcessOverride.html) covers
the rest: what the switch deliberately leaves in place and why, and what
Dialyzer does with a disabled build.

## Enforcing the conventions (optional Credo checks)

Ambient ships four Credo checks that keep direct clock/RNG/env/config reads from
sneaking back in. **They're opt-in**: `credo` is an *optional* dependency, so if
you don't use Credo you pull nothing and the checks aren't even compiled. If you
do, enable them in `.credo.exs`:

```elixir
checks: %{
  extra: [
    {Ambient.Credo.NoDirectClock, replacement: "MyApp.Clock"},
    {Ambient.Credo.NoDirectRandom, replacement: "MyApp.Random"},
    {Ambient.Credo.NoDirectEnv, replacement: "MyApp.Env", exempt_suffixes: ["config/runtime.exs"]},
    {Ambient.Credo.NoDirectConfig, otp_app: :my_app, replacement: "MyApp.Config"}
  ]
}
```

`replacement:` is the module name shown in the message, and it defaults to
`Ambient.Clock` / `Ambient.Random` / `Ambient.Env` – so set it to
[your own wrapper](#wrap-it-in-your-own-namespace) or Credo will tell people to
call a module your codebase deliberately doesn't.

`NoDirectClock` flags `DateTime.utc_now/0` & friends; `NoDirectRandom` flags the
`:rand` read and seed functions plus `Enum.shuffle|random|take_random` (but
allows `:crypto.strong_rand_bytes/1`); `NoDirectEnv` flags `System.get_env`,
`put_env`, `fetch_env`, `fetch_env!`, `delete_env` and `:os.getenv`;
`NoDirectConfig` flags runtime `Application.get_env|fetch_env|fetch_env!` for
your app. All four also take `exempt_suffixes:`, a list of paths to skip.

## Errors

Misuse raises `Ambient.Error` with a machine-readable `:reason`
(`:overrides_disabled`, `:server_not_started`, `{:not_shared_owner, pid}`,
`:cant_allow_in_shared_mode`, `:not_a_value_module`,
`{:server_start_failed, reason}`) – match on `:reason`, not on message text. A
bad *argument value* (`MyApp.Clock.advance(weeks: 1)`) raises `ArgumentError`
instead: `Ambient.Error` means Ambient is in the wrong state, not that you
passed the wrong term. See [`Ambient.Error`](https://hexdocs.pm/ambient/Ambient.Error.html).

## How it compares

### The patch-based libraries – the closest alternatives

**[Repatch](https://hexdocs.pm/repatch)** is the strongest one, and for the
built-ins it's close to a superset. It patches "any function or macro, Elixir
or Erlang, private or public (except BIF/NIF)", with three modes – `:local`,
`:shared` (the setting process, its spawned tasks and processes passed to
`Repatch.allow/3`, chainable) and `:global`. So it reaches
`DateTime.utc_now/0`, `System.get_env/1`, `Application.get_env/3` and `:rand`
directly, with the same ownership story Ambient has, **no wrapper module, no
call-site change, no production dependency** and one `Repatch.setup()` line.

**[Mimic](https://hexdocs.pm/mimic)** is the same idea, narrower: private mode
by default, `Task` processes auto-allowed, `Mimic.copy/1` called from
`test_helper.exs` so nothing touches production, global mode for `async: false`.

**[Patch](https://hexdocs.pm/patch)** is the older, ergonomic one, and the
exception: it recompiles modules and so "alters the global execution
environment", which is why its own docs state "Patch is not compatible with
`async: true`". Same trade as [Klotho](https://hex.pm/packages/klotho) below –
convenient, but it takes concurrency off the table.

What Ambient offers against them:

| | Patch-based (Repatch / Mimic) | Ambient |
|---|---|---|
| Call sites change | no | yes – you call a wrapper |
| Reaches a dependency's internal `DateTime.utc_now/0` | ✅ | ❌ |
| Seam visible at the call site | no | yes |
| Rewrites modules you don't own | yes | no |
| Keyed overrides (`Config.put(:key, v)`) | patch `get_env/3` with a fallthrough clause | first-class |
| Finished semantics (`advance/1`, `unset/1`, seeded RNG) | build them yourself | built in |
| Test seam absent from the release build | n/a – test-only anyway | the wrapper compiles to the wrapped call |

The last row is the one that isn't taste: it's what lets `Ambient.Random`
expose a seedable RNG *and* a credential-safe `bytes/1` in the same module.

### The mocking libraries

- **[Mox](https://hexdocs.pm/mox)** overrides *behaviour* (what a collaborator
  does) against an explicit contract, and is the right tool for that. It's an
  awkward fit for a value read incidentally several layers down: every test
  that transitively touches the clock has to declare it or hit
  `Mox.UnexpectedCallError`, and hoisting a `stub` into a global `setup` is
  this library with more steps. Its private mode does use `$callers`;
  `set_mox_global/0` is documented as incompatible with `async: true`, same as
  Ambient's shared mode. Mox and Ambient are complementary – Ambient stays out
  of mocking.
- **[Klotho](https://hex.pm/packages/klotho)** fakes timers and the clock, but
  its mock is global: it can't be used from tests running in parallel.

### The ownership plumbing

- **[nimble_ownership](https://github.com/dashbitco/nimble_ownership)**
  ([docs](https://hexdocs.pm/nimble_ownership)) solves the same ownership
  problem and is what Mox is built on. Differences: it keeps state in a
  GenServer, so reads go through the server rather than being direct ETS
  lookups; and caller inheritance isn't implicit – the docs note the server
  "does not consider the direct and indirect 'children' of a PID", so you pass
  `Process.get(:"$callers", [])` yourself. Ambient walks that chain for you and
  reads from public ETS, then adds the built-in values, the Facade, the Credo
  checks and the compile-time switch. If you only need the plumbing, it's the
  more focused library.
- **[Ecto.Adapters.SQL.Sandbox](https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Sandbox.html)**
  is the direct inspiration for `allow/3` and shared mode, and the precedent for
  the whole approach.

### The globals being replaced

**[Application.put_env/3](https://hexdocs.pm/elixir/Application.html#put_env/4)**
and **[System.put_env/2](https://hexdocs.pm/elixir/System.html#put_env/2)** are
what `Ambient.Config` and `Ambient.Env` exist to replace in tests: both are
VM-global, so neither is safe under `async: true`.

## License

MIT © Mariusz Zak
