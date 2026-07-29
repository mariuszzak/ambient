# Ambient

Process-scoped value overrides for Elixir – a frozen **clock**, a seeded
**random number generator**, overridable **env vars** and a per-test **config**
layer that survive across process boundaries, never leak between `async: true`
tests, and cost nothing in production.

An *ambient value* is one resolved implicitly from the surrounding context
rather than threaded through arguments. Ambient lets a test set such a value –
the current time, a random seed, `DATABASE_URL`, a config entry – scoped to its
process **and everything that process spawns**, with automatic cleanup on exit.

```elixir
test "a token expires after 24 hours" do
  Ambient.Clock.set(~U[2026-01-01 09:00:00Z])
  token = Tokens.issue(user)          # any process it spawns sees this clock

  Ambient.Clock.advance(hours: 23)
  assert Tokens.valid?(token)

  Ambient.Clock.advance(hours: 2)
  refute Tokens.valid?(token)
end
```

- [Why](#why)
- [Install](#install)
- [Built-in values](#built-in-values) – [Config](#config), [Clock](#clock), [Random](#random), [Env](#env)
- [Build your own](#build-your-own)
- [Re-exporting under your own namespace](#re-exporting-under-your-own-namespace)
- [Reaching a process you didn't spawn](#reaching-a-process-you-didnt-spawn)
- [Shared mode](#shared-mode-for-async-false-tests)
- [Errors](#errors)
- [The compile-time switch](#the-compile-time-switch)
- [Dialyzer](#dialyzer)
- [Production cost](#production-cost)
- [Credo checks](#enforcing-the-conventions-optional-credo-checks)
- [How it works](#how-it-works)
- [How it compares](#how-it-compares)

## Why

Overriding a global for one test without disturbing its neighbours is
surprisingly hard:

| Approach | Per-test isolation | Survives a spawned process | Auto-cleanup |
|---|---|---|---|
| `Application.put_env/3` | ❌ global – breaks `async: true` | ✅ | ❌ |
| `System.put_env/2` | ❌ global – breaks `async: true` | ✅ | ❌ |
| `Process.put/2` | ✅ | ❌ lost across the boundary | ✅ (dies with the pid) |
| **Ambient** | ✅ | ✅ (`$callers` + `allow/3`) | ✅ (monitored) |

Ambient gives you `Process.put`-style isolation **plus** cross-process
inheritance (the same `$callers` mechanism Ecto's SQL Sandbox uses, plus an
explicit `allow/3` for long-lived processes), with values cleaned up
automatically when the owning test process exits.

And in production the override machinery isn't compiled in at all – see
[Production cost](#production-cost).

## Install

```elixir
def deps do
  [{:ambient, "~> 0.1"}]
end
```

Not a test-only dependency: you read through `Ambient.Clock` and
`MyApp.Config` from application code. The override machinery is what's absent
from production, not the library – see [the compile-time
switch](#the-compile-time-switch).

Opt into the override machinery, in `config/config.exs`:

```elixir
config :ambient, enable_overrides: config_env() != :prod
```

It defaults to `false`, so a build that doesn't set it – your release – has no
override machinery compiled in at all. See [the compile-time
switch](#the-compile-time-switch).

Gate on `!= :prod` rather than `== :test`: `:prod` is the only env where the
guarantee matters, and Dialyzer runs in `:dev` – see
[Dialyzer](#dialyzer).

Then start one override server per table before the suite runs, in
`test/test_helper.exs`:

```elixir
Ambient.start_servers([Ambient.Clock, Ambient.Random, Ambient.Env, MyApp.Config])
ExUnit.start()
```

Forgetting the config line fails loudly at `Ambient.start_servers/1`; forgetting
a table surfaces at the first write to it, as `:server_not_started`.

A `use Ambient.Facade` wrapper can be registered in place of the module it
wraps – it passes `__ambient_table__/0` through.

## Built-in values

Four ready-made ambient values. Each is a thin wrapper you call from
application code instead of the global it replaces, plus test-only setters that
are scoped to the calling process and everything it spawns.

### Config

The one most apps reach for first. `Application.get_env/3` is how Elixir apps
read their settings, and `Application.put_env/3` is how tests usually override
them – except that `put_env` mutates global state, so two `async: true` tests
touching the same key clobber each other, and a value left behind leaks into
every later test in the run.

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
isn't compiled in at all – `get/2` *is* `Application.get_env/3` (see
[Production cost](#production-cost)).

In tests, override per process. No `setup`/`on_exit` pairing, no restoring the
old value, no `async: false`:

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

The override dies with the test process, so the second test sees the real
value even while the first is still running.

It reaches spawned work too – a `Task` your code starts inherits it through
`$callers` with no setup:

```elixir
test "the background charge sees the override" do
  MyApp.Config.put(:retry_limit, 1)

  assert Task.async(fn -> Billing.charge(invoice) end) |> Task.await() ==
           {:error, :exhausted}
end
```

For a long-lived process the test didn't spawn – a named GenServer, an Oban
worker – grant it access explicitly (see
[Reaching a process you didn't spawn](#reaching-a-process-you-didnt-spawn)):

```elixir
MyApp.Config.allow(genserver_pid)
```

The full surface:

```elixir
MyApp.Config.get(:key, default)     # read: override, else Application.get_env/3
MyApp.Config.put(:key, value)       # override for this process and its children
MyApp.Config.revert(:key)           # drop one override, back to app env
MyApp.Config.reset()                # drop every override this process set
MyApp.Config.overridden?(:key)      # is one in scope?
MyApp.Config.allow(pid)             # let another process read this one's overrides
```

Bind as many accessors as you have apps – each `otp_app` gets its own table, so
an umbrella's apps never collide.

### Clock

Time is the other classic untestable global. Read it through `Ambient.Clock`
and a test can freeze it, or travel, without `Process.sleep/1` or hand-rolled
date arithmetic:

```elixir
# app code – instead of DateTime.utc_now/0, Date.utc_today/0, …
Ambient.Clock.utc_now()
Ambient.Clock.utc_today()
Ambient.Clock.naive_utc_now()
Ambient.Clock.now("Europe/Warsaw")   # needs a configured time zone database

# tests
Ambient.Clock.set(~U[2026-01-01 09:00:00Z])
Ambient.Clock.advance(days: 1)     # also :hours, :minutes, :seconds, or a bare int
Ambient.Clock.advance(hours: 1, minutes: 30)   # units are summed
Ambient.Clock.advance(-90)         # backwards, in seconds
Ambient.Clock.reset()
```

```elixir
test "a token expires after 24 hours" do
  Ambient.Clock.set(~U[2026-01-01 09:00:00Z])
  token = Tokens.issue(user)

  Ambient.Clock.advance(hours: 23)
  assert Tokens.valid?(token)

  Ambient.Clock.advance(hours: 2)
  refute Tokens.valid?(token)
end
```

`set/1` and `advance/1` return the new time, so they compose into assertions.

### Random

```elixir
# app code
Ambient.Random.uniform(100)        # 1..100
Ambient.Random.uniform()           # float in [0.0, 1.0)
Ambient.Random.normal(0.0, 1.0)
Ambient.Random.shuffle(cards)
Ambient.Random.take_random(deck, 5)
Ambient.Random.bytes(32)

# tests – same seed replays the same stream every run
Ambient.Random.seed(42)
first = Ambient.Random.uniform(100)
Ambient.Random.seed(42)
assert Ambient.Random.uniform(100) == first
```

Repeated calls in one process advance the stream, so four `shuffle/1` calls
give four different permutations – the same four every run.

Across processes it's a **fork**, not one shared stream: a child inherits the
owner's state as of the seed and advances its own copy. Sequential work is
unsurprising (a child that draws after the parent continues where the parent
left off), but **concurrent siblings each get the same values**:

```elixir
Ambient.Random.seed(42)
1..4 |> Enum.map(fn _ -> Task.async(fn -> Ambient.Random.bytes(4) end) end)
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

Shared mode routes every draw through one atomically-advanced stream, so
concurrent callers never collide.

#### Cryptography

Seedable and unpredictable are opposites, so the rule is per-function, not
per-module:

| | No seed in scope | Under `seed/1` |
|---|---|---|
| `bytes/1` | `:crypto.strong_rand_bytes/1` – **credential-safe** | deterministic, not safe |
| `uniform`, `normal`, `shuffle`, `random`, `take_random` | `:rand` (`exsss`) – **never** credential-grade | deterministic |

```elixir
# fine – strong in production, replayable in tests
Ambient.Random.bytes(32) |> Base.url_encode64(padding: false)

# never – a token is not a dice roll
Enum.map(1..32, fn _ -> Ambient.Random.uniform(256) end)
```

The right-hand column can't happen in production, because the
[compile-time switch](#the-compile-time-switch) doesn't compile the seeded
clause at all – there is no code path from a seed to `bytes/1` to reach, no
matter what a `$callers` chain, an `allow/3` grant, a seeds script or a remote
console does. That holds only if you derive the flag from `config_env/0`; a
build that hard-codes it on has ordinary seeded bytes, and warns at compile
time when Ambient can tell it's a prod build.

### Env

`System.put_env/2` mutates the whole VM: two `async: true` tests setting the
same variable clobber each other, and a leaked value survives into every later
test in the run.

```elixir
# app code – instead of System.get_env/1
Ambient.Env.get("DATABASE_URL")
Ambient.Env.get("PORT", "4000")
Ambient.Env.fetch!("SECRET_KEY_BASE")

# tests
Ambient.Env.put("FEATURE_X", "true")
Ambient.Env.put_all(%{"REGION" => "eu-west-1", "TIER" => "premium"})
Ambient.Env.unset("HOME")      # override it as absent, even though it really is set
Ambient.Env.revert("HOME")     # drop the override, see the real value again
Ambient.Env.reset()            # drop every override this process set
```

`unset/1` and `revert/1` are deliberately different: `unset/1` *writes* an
override meaning "absent", which is how you test that path for a variable that
really is set; `revert/1` removes an override.

> **Runtime reads only.** An override can only affect a read that happens while
> it is in scope. Anything resolved at boot (`config/runtime.exs`) or at compile
> time has already been read. Wrap the read in a function your code calls when
> it needs the value.

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
`__ambient_table__/0` – all `defoverridable` – and imports the `get_or/2` macro.
If your reads also *write* (as `Ambient.Random` does, advancing its seed), write
back with `ProcessOverride.put_resolved/3` so it keeps working under shared
mode.

`get_or/2` is a macro on purpose: it expands at compile time, so in a build
without overrides the lookup disappears entirely and only the fallback
expression remains. `def current, do: get_or(:tenant, MyApp.Tenant.Default)`
compiles to `def current, do: MyApp.Tenant.Default`. The fallback is evaluated
only on a miss, so `get_or(:key, expensive_call())` doesn't pay for a call it
doesn't need.

## Re-exporting under your own namespace

Prefer to call `MyApp.Clock` instead of `Ambient.Clock` across your app? Wrap a
value module with `Ambient.Facade` – the delegates are derived at compile time,
so the wrapper never drifts when the wrapped module gains a function:

```elixir
defmodule MyApp.Clock do
  use Ambient.Facade, for: Ambient.Clock
end

MyApp.Clock.set(~U[2026-01-01 00:00:00Z])   # delegates to Ambient.Clock
```

Narrow the surface with `:only` / `:except` (names or `{name, arity}` pairs):

```elixir
use Ambient.Facade, for: Ambient.Clock, only: [:utc_now, :utc_today]
use Ambient.Facade, for: Ambient.Random, except: [:seed]
```

## Reaching a process you didn't spawn

Plain `Task.async`/`Agent` children inherit automatically via `$callers`. For a
long-lived process the test didn't spawn (a named GenServer, an Oban worker),
authorise it explicitly – the same pattern as `Ecto.Adapters.SQL.Sandbox.allow/3`:

```
   test process  ──put/set/seed──▶  ETS override
        │
        ├── Task.async child ──────▶ inherits via $callers   (no setup)
        │
        └── Ambient.Clock.allow(worker_pid)
                     │
              worker_pid ──────────▶ inherits via allow chain
```

```elixir
Ambient.Clock.allow(worker_pid)
Ambient.Random.allow(worker_pid)
Ambient.Env.allow(worker_pid)
MyApp.Config.allow(genserver_pid)
```

Grants chain: if A allows B and B allows C, C resolves through to A. Cycles
terminate rather than spinning.

## Shared mode (for `async: false` tests)

Sometimes `allow/3` is the wrong tool: the process you need to reach is deep
inside a supervision tree, or you don't have its pid at all.
`Ambient.set_shared/2` makes one process's overrides the ones **every** process
reads:

```elixir
use ExUnit.Case, async: false   # required – this is global state

test "the whole system sees the frozen clock" do
  Ambient.Clock.set(~U[2026-01-01 09:00:00Z])
  Ambient.set_shared(Ambient.Clock)
  on_exit(fn -> Ambient.set_private(Ambient.Clock) end)

  # any process, however spawned, now reads that clock
end
```

`Ambient.start_servers/1`, `set_shared/2` and `set_private/1` all take one
value module or a list of them.

Same rule as `Ecto.Adapters.SQL.Sandbox`'s shared mode and `Mox.set_mox_global/0`:
**never in an `async: true` test**, or a concurrent test will see your clock.

While a table is shared:

- only the shared owner may write – `put/3` and `set_shared/2` from anyone else
  raise `{:not_shared_owner, pid}`, so another test can't silently steal the
  table;
- `allow/3` is refused, since every process already reads the owner's values;
- `set_private/1` is deliberately open to any process – it's the way back to a
  sane state, and `on_exit/1` runs in a different process from the test;
- `delete/2` and `reset/0`-style teardown stay scoped to the caller's own rows,
  so a non-owner's `Clock.reset()` doesn't (and can't) clear the shared value;
- the owner is monitored, so a crashed test drops the table back to private on
  its own rather than leaving the suite globally overridden.

`Ambient.ProcessOverride.mode/1` reports `:private` or `{:shared, pid}`.

## Errors

Every Ambient misuse raises `Ambient.Error` with a machine-readable `:reason`
(`:overrides_disabled`, `:server_not_started`, `{:not_shared_owner, pid}`,
`:cant_allow_in_shared_mode`, `:not_a_value_module`, `{:server_start_failed, reason}`).
Match on `:reason`, not on message text:

```elixir
rescue
  e in Ambient.Error ->
    case e.reason do
      :server_not_started -> start_and_retry()
      _ -> reraise(e, __STACKTRACE__)
    end
end
```

Bad *argument values* (`Ambient.Clock.advance(weeks: 1)`) still raise
`ArgumentError` – `Ambient.Error` means Ambient is in the wrong state, not that
you passed the wrong term.

## The compile-time switch

Every override path is gated on one flag, resolved at compile time via
`Application.compile_env/3`:

```elixir
# config/config.exs
config :ambient, enable_overrides: config_env() != :prod
```

Default `false`. In a build that didn't opt in, no Ambient API can produce an
override:

- `Ambient.start_servers/1`, `ProcessOverride.Server.start_link/1` and
  `Server.init/1` all refuse to create the ETS table;
- `put/3`, `allow/3`, `set_shared/2` raise, as do the built-ins' writers
  (`Clock.set/1`, `Random.seed/1`, `Env.put/2`, `put_override/2`, …);
- the built-ins' override branches aren't compiled at all – see
  [Production cost](#production-cost);
- `reset/0`-style teardown stays a safe no-op, so `on_exit` helpers don't need
  guarding.

What it deliberately does **not** do: `ProcessOverride.fetch/2` keeps its ETS
lookup in disabled builds, because a clause hard-wired to `:error` makes every
caller's `{:ok, _}` branch provably dead and consumers compiling with
`--warnings-as-errors` would fail on it. So a hand-rolled
`:ets.new(:ambient_clock_overrides, [:named_table, :public])` plus a row *is*
visible to `fetch/2`, `mode/1` and `overridden?/1`. It is **not** visible to
the built-ins' actual reads – `get_or/2` compiled those away, so
`Clock.utc_now/0` and a generated `MyApp.Config.get/2` ignore it. Forging one needs arbitrary
code execution inside the node anyway.

Three more things worth knowing:

- Derive the flag from `config_env/0`. Compiling Ambient with it hard-coded on
  warns whenever Ambient can tell it's building for `:prod` – such a release
  carries the machinery and `bytes/1` loses its guarantee. Ambient sees only
  `MIX_ENV` and the build directory, so a project with
  `build_per_environment: false` gets no warning; derive the flag and the
  question doesn't arise.
- Mix records the value in the app manifest, so a **release** whose runtime
  config disagrees aborts at boot rather than drifting. (A `mix run` in `:prod`
  does not perform that check.)
- It's resolved per `_build` env. Build releases with `MIX_ENV=prod`; a release
  built with `MIX_ENV=test` would carry the machinery.

`Ambient.ProcessOverride.enabled?/0` reports the current build. Use it in a
module body: its value is fixed when Ambient compiles, so a runtime branch on
it is just dead code.

### Dialyzer

Gate the flag on `config_env() != :prod`, not `== :test`.

In a build without overrides the writers raise, so their success typing is
`none()` – and `dialyxir` runs in `:dev` by default, so gating on `== :test`
points Dialyzer at exactly that build. Ambient's generated specs say
`no_return()` there, which keeps the generated code itself clean, but a
function of *yours* that wraps a writer still can't return:

```elixir
def put(tenant), do: put_override(:tenant, tenant)
# warning: Function put/1 has no local return
```

That is Dialyzer being right. Measured on a small consuming app with one
`use Ambient.Config` and one `use Ambient.Value`:

| `enable_overrides` | Warnings in the consumer's own modules |
|---|---|
| `config_env() != :prod` | **0** |
| `config_env() == :test` | **1** – the wrapper above |

So gate on `!= :prod` and the question doesn't arise. If you'd rather keep
`== :test`, move such wrappers behind `if Ambient.ProcessOverride.enabled?()`,
which compiles them out of the build that can't run them anyway.

## Production cost

None worth measuring. `get_or/2` expands to the fallback expression alone, so
each wrapper compiles down to the function it wraps:

| Wrapper | Production build compiles to |
|---|---|
| `Ambient.Clock.utc_now/0` | `DateTime.utc_now/0` |
| `Ambient.Random.bytes/1` | `:crypto.strong_rand_bytes/1` |
| `Ambient.Random.uniform/1` | `:rand.uniform/1` |
| `Ambient.Env.get/2` | `System.get_env/2` |
| `MyApp.Config.get/2` | `Application.get_env/3` |

No ETS lookup, no branch, no message round-trip. `Ambient.ProcessOverride`'s
own `fetch/2` still costs one `:ets.whereis/1`, but the built-ins don't call it
in a disabled build.

## Enforcing the conventions (optional Credo checks)

Ambient ships four Credo checks that keep direct clock/RNG/env/config reads from
sneaking back in. **They're opt-in**: `credo` is an *optional* dependency, so if
you don't use Credo you pull nothing and the checks aren't even compiled. If you
do, enable them in `.credo.exs`:

```elixir
checks: %{
  extra: [
    {Ambient.Credo.NoDirectClock, []},
    {Ambient.Credo.NoDirectRandom, []},
    {Ambient.Credo.NoDirectEnv, exempt_suffixes: ["config/runtime.exs"]},
    {Ambient.Credo.NoDirectConfig, otp_app: :my_app, replacement: "MyApp.Config"}
  ]
}
```

- `NoDirectClock` flags `DateTime.utc_now/0` & friends; `NoDirectRandom` flags
  `:rand.*` / `Enum.shuffle|random|take_random` (but allows
  `:crypto.strong_rand_bytes/1`); `NoDirectEnv` flags `System.get_env/*` and
  `System.put_env/*`; `NoDirectConfig` flags runtime
  `Application.get_env(:my_app, …)`.
- All take `replacement:` (the wrapper name shown in the message) and
  `exempt_suffixes:` (paths to skip). So if you re-export under your own
  namespace, point them at it:

  ```elixir
  {Ambient.Credo.NoDirectClock, replacement: "MyApp.Clock", exempt_suffixes: ["lib/my_app/clock.ex"]}
  ```

## How it works

Each override domain is a named, public ETS table owned by an
`Ambient.ProcessOverride.Server`. Writes are keyed `{owner_pid, key}`; reads
resolve through **self → allow chain → `$callers`**, or straight to the shared
owner when the table is shared. The server monitors every writer and clears its
rows (and any `allow` rows pointing at it) on exit – so concurrent `async: true`
tests never see each other's values and nothing leaks.

Reads are plain ETS lookups in the calling process: no GenServer call, no
serialization point between concurrent tests.

## How it compares

- **[nimble_ownership](https://github.com/dashbitco/nimble_ownership)**
  ([docs](https://hexdocs.pm/nimble_ownership)) solves the same
  ownership/allowance problem, and is what Mox is built on. It keeps state in a
  GenServer, so every read is a `GenServer.call`, and it offers shared mode,
  lazy allowances and manual cleanup. Ambient reads from public ETS instead,
  and adds what `nimble_ownership` deliberately doesn't: the built-ins, the
  Facade, the Credo checks, and the compile-time switch that makes wrappers
  free in production.
- **[Mox](https://github.com/dashbitco/mox)**
  ([docs](https://hexdocs.pm/mox)) overrides *behaviour* (what a module does).
  Ambient overrides *values* (what a function reads). They're complementary,
  and Ambient deliberately stays out of mocking.
- **[Ecto.Adapters.SQL.Sandbox](https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Sandbox.html)**
  is the direct inspiration for `allow/3` and shared mode.
- **[Application.put_env/3](https://hexdocs.pm/elixir/Application.html#put_env/4)**
  and **[System.put_env/2](https://hexdocs.pm/elixir/System.html#put_env/2)**
  are what `Ambient.Config` and `Ambient.Env` exist to replace in tests: both
  are VM-global, so neither is safe under `async: true`.

## License

MIT © Mariusz Zak
