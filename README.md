# Ambient

Per-process `Application.get_env` overrides, so config-dependent tests can stay
`async: true` – plus the same machinery for any ambient value of your own.

A test sets a value; it applies to that process **and everything that process
spawns**, never to a concurrent test, and is cleaned up when the test exits. In
production the override machinery isn't compiled in at all.

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

- [Why config](#why-config)
- [Should you use this?](#should-you-use-this)
- [Install](#install)
- [Config](#config) – [Nested keys](#nested-keys)
- [Build your own](#build-your-own)
- [Clock, the worked example](#clock-the-worked-example)
- [Wrap it in your own namespace](#wrap-it-in-your-own-namespace)
- [Reaching a process you didn't spawn](#reaching-a-process-you-didnt-spawn)
- [Shared mode](#shared-mode-for-async-false-tests)
- [How it works](#how-it-works)
- [The compile-time switch and production cost](#the-compile-time-switch-and-production-cost)
- [Credo checks](#enforcing-the-conventions-optional-credo-checks)
- [Errors](#errors)
- [What it costs to adopt](#what-it-costs-to-adopt)
- [How it compares](#how-it-compares)

## Why config

`Application.put_env/3` is VM-global. A test that overrides a setting can't be
`async: true`, and that isn't a rare shape: in the app this library was built
for, **17 config keys are read by two or more concurrent test files** – one of
them by six. Every one of those files would have to be serialised, or paired
with `setup`/`on_exit` restore logic that a crash can still leak past.

Unlike a clock or an RNG, there is no fake to write here. `Application.get_env/3`
is a keyed lookup, not a contract you can swap: a per-test config layer *is* an
ownership problem. The obvious places to keep that state give you one property
or the other, never both:

| Where the value lives | Isolated per test | Reachable from another process |
|---|---|---|
| compile-time DI (`@clock` attribute) | ❌ one implementation per build | ✅ needs no parameter |
| a threaded value or fake | ✅ | ❌ needs a parameter at every hop |
| `Process.put/2` | ✅ | ❌ lost at the boundary |
| `Application.put_env/3` | ❌ VM-global | ✅ |
| **ETS keyed by owner + `$callers` + monitors** | ✅ | ✅ |

Only the last row gets both, and it isn't a novel idea – it's what
[`Ecto.Adapters.SQL.Sandbox`](https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Sandbox.html)
does for database connections. Its ownership manager keeps a protected,
read-concurrent ETS table keyed by owner pid, and resolves a checkout
client-side by walking `[caller | Process.get(:"$callers")]` against it; only
the writes go through a GenServer. Threading a `conn` through every function is
possible and nobody does it, so Ecto pays for an ownership mechanism instead.
Ambient is the same mechanism for arbitrary values, plus a compile-time switch
that keeps it out of your release.

**Pass the value when you can.** A parameter beats an ambient read every time,
and a closure captures across a process boundary perfectly well:

```elixir
now = MyApp.Clock.utc_now()
Task.async(fn -> Billing.charge(invoice, now) end)
```

This library is for the reads where there is no parameter to pass – config
being the clearest case, and these being the others:

**The call site isn't yours.** Ecto generates timestamps from an MFA it invokes
itself, with arguments it chose:

```elixir
@timestamps_opts [autogenerate: {MyApp.Clock, :naive_utc_now, []}]
```

Same shape for changeset autogeneration, Phoenix plugs, Absinthe middleware,
telemetry handlers.

**The process isn't in your spawn tree.** A GenServer started by the app
supervisor and ticking on `handle_info(:tick)`; a LiveView Phoenix spawned; a
live Oban queue in an integration test. No closure to capture into – and
launch-time dependency injection doesn't reach these either, because the test
didn't launch them.

## Should you use this?

**Don't bother if:**

- **Your tests don't spawn, and you only need a clock.** A twelve-line
  `Process.put/2` fake plus `Application.compile_env/3` is per-test isolated,
  `async: true`-safe, and costs you no dependency at all.
- **You can pass the value.** Do that instead.
- **You're comfortable patching modules.** [Repatch](https://hexdocs.pm/repatch)
  reaches `DateTime`, `System`, `Application` and `:rand` directly – no
  wrapper, no call-site change, no production dependency, same per-process
  ownership model. Lower adoption cost than this library. See
  [How it compares](#how-it-compares).

**Reach for it if:**

- **`Application.put_env/3` is why part of your suite is `async: false`.** This
  is the strongest case, because it's the one with no cheaper answer.
  `MyApp.Config.put(:key, value)` is the whole API, and it takes
  [nested keys](#nested-keys), which is how real config is written.
- **You want the seam explicit.** The wrapper is real API: greppable,
  documented, [enforceable by Credo](#enforcing-the-conventions-optional-credo-checks),
  and no module you don't own gets rewritten.
- **You have ambient values of your own** – current tenant, acting user,
  request id, a seeded RNG. [`use Ambient.Value`](#build-your-own) gives them
  the same machinery in about ten lines each.

**Two things Ambient doesn't do.** It can't touch a dependency that calls
`DateTime.utc_now/0` in its own internals – Ambient only redirects reads that go
through an Ambient wrapper, and you can't add a wrapper to code you don't own.
And there's no `verify_on_exit!`: forget `Clock.set/1` and the test quietly
reads the real clock instead of failing loudly the way an unstubbed Mox call
would.

## Install

```elixir
def deps do
  [{:ambient, "~> 0.2"}]
end
```

Not a test-only dependency: you read through `MyApp.Config` and `MyApp.Clock`
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

Then define your accessor and start one override server per table before the
suite runs, in `test/test_helper.exs`:

```elixir
Ambient.start_servers([MyApp.Config, MyApp.Clock])
ExUnit.start()
```

Forgetting the config line fails loudly at `Ambient.start_servers/1`; forgetting
a table surfaces at the first write to it, as `:server_not_started`. That's also
what you'll hit trying to set an override in `iex -S mix`, where nothing has
started the servers – call `Ambient.start_servers/1` there too.

## Config

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

The override dies with the test process, and reaches spawned work – a `Task`
your code starts inherits it through `$callers` with no setup:

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

### Nested keys

Most real config isn't flat. `config :my_app, :oauth, client_id: "…"` reads
back as a keyword list, so the call site is
`Application.get_env(:my_app, :oauth)[:client_id]`. Pass a path and both the
read and the override target the leaf:

```elixir
MyApp.Config.get([:oauth, :client_id], "default")
MyApp.Config.put([:oauth, :client_id], "test-client")
```

Paths step through keyword lists and maps, to any depth. A missing key anywhere
along the way yields the default, exactly as `Application.get_env/3` does for a
missing top-level key.

Overrides resolve **longest prefix first**: an override on the exact path wins,
then one on each shorter prefix, then app env. So pinning a whole group still
works, and a group override is visible to leaf reads:

```elixir
MyApp.Config.put(:oauth, client_id: "a", secret: "b")
MyApp.Config.get([:oauth, :client_id])   #=> "a"
```

It does not work in reverse – overriding a leaf doesn't synthesize a parent, so
`get(:oauth)` after `put([:oauth, :client_id], …)` returns the unmodified
app-env group. Override at the level you read at. A one-element path is the
same key as the bare atom, so `[:port]` and `:port` are interchangeable.

## Build your own

Nothing about `Ambient.Config` or `Ambient.Clock` is privileged – they're both
`use Ambient.Value`. If your app has an ambient value of its own (the current
tenant, the acting user, a request id), this is the supported way to make it as
testable:

```elixir
defmodule MyApp.Tenant do
  use Ambient.Value, table: :my_app_tenant_overrides

  def current, do: get_or(:tenant, MyApp.Tenant.Default)
  def put(tenant), do: put_override(:tenant, tenant)
end

Ambient.start_servers([MyApp.Tenant])   # in test_helper.exs, like a built-in
```

`use Ambient.Value` generates `put_override/2`, `delete_override/1`,
`delete_all/0`, `overridden?/1`, `allow/2`, `set_shared/1`, `set_private/0` and
`__ambient_table__/0` – all `defoverridable` – imports the `get_or/2` macro, and
sets `@ambient_enabled` for the rare hand-rolled branch (see
[the compile-time switch](#the-compile-time-switch-and-production-cost)).

A module wrapping a specific domain usually adds its own verbs on top –
`Config`'s `put/2`, `Clock.set/1` – and leaves the generic layer below for
everything else.

`get_or/2` is a macro on purpose: it expands at compile time, so in a build
without overrides the lookup disappears entirely and only the fallback
expression remains. `def current, do: get_or(:tenant, MyApp.Tenant.Default)`
compiles to `def current, do: MyApp.Tenant.Default`. The fallback is evaluated
only on a miss, so `get_or(:key, expensive_call())` doesn't pay for a call it
doesn't need.

### When your reads also write

A seeded RNG advances its state on every draw. For that shape use
`ProcessOverride.get_and_update/3` rather than a `fetch` + `put` pair – it
resolves, applies your function and writes back atomically, which is what keeps
such a module correct under [shared mode](#shared-mode-for-async-false-tests),
where every process is reading and writing the *same* row:

```elixir
defmodule MyApp.Random do
  use Ambient.Value, table: :my_app_random_overrides

  def seed(n), do: put_override(:rng, :rand.seed_s(:exsss, {n, n, n}))

  def uniform(n) do
    case ProcessOverride.get_and_update(@ambient_table, :rng, &:rand.uniform_s(n, &1)) do
      {:ok, value} -> value
      :error -> :rand.uniform(n)      # no seed in scope – fall through
    end
  end
end
```

Your function takes the current value and returns `{result, new_value}`. If it
raises, the exception surfaces in your process, not the table's server.

Note the trade this shape carries, whichever library provides it: across
processes an inherited seed is a **fork**, not one shared stream, so concurrent
siblings each draw the same values. That's deliberate – which sibling gets which
value from a single stream depends on scheduling, so *distinct* and
*reproducible* cannot both hold under concurrency. Shared mode gives you one
globally advancing stream instead, at the cost of `async: false`.

## Clock, the worked example

`Ambient.Clock` ships built in, and is what a `use Ambient.Value` module looks
like when it's finished. Read time through it and a test can freeze time, or
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

## Wrap it in your own namespace

Adopting Ambient otherwise means a third-party module name at every clock read
in your application code – and backing out would mean touching all of them. So
define your own module and call that everywhere. The dependency is then named
in exactly two modules of your application code:

```elixir
defmodule MyApp.Config do
  use Ambient.Config, otp_app: :my_app
end

defmodule MyApp.Clock do
  use Ambient.Facade, for: Ambient.Clock
end
```

The delegates are derived at compile time, so a wrapper never drifts when the
wrapped module gains a function, and `Ambient.start_servers/1`, `set_shared/2`
and `set_private/1` all accept your wrapper rather than the module behind it.

Narrow the surface with `:only` / `:except` (names or `{name, arity}` pairs):

```elixir
use Ambient.Facade, for: Ambient.Clock, only: [:utc_now, :utc_today]
```

The rest of this README uses `MyApp.*` on that assumption. Calling
`Ambient.Clock` directly works identically – you just spread the dependency
across your call sites.

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
LiveView's `view.pid`. Grants chain: if A allows B and B allows C, C resolves
through to A. Cycles terminate rather than spinning, and still fall through to
`$callers`.

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
  keep working atomically from every process;
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

## How it works

Each override domain is a named, public ETS table owned by an
`Ambient.ProcessOverride.Server`. Writes are keyed `{owner_pid, key}`; reads
resolve through **self → allow chain → `$callers`**, or straight to the shared
owner when the table is shared. The server monitors every writer and clears its
rows (and any `allow` rows pointing at it) on exit – so concurrent `async: true`
tests never see each other's values and nothing leaks.

Reads are plain ETS lookups in the calling process: no GenServer call, no
serialization point between concurrent tests. Writes do go through the server,
which is what lets a monitor and a row be established together rather than
racing an exit in the gap.

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
| `MyApp.Config.get/2` | `Application.get_env/3` |
| `Ambient.Clock.utc_now/0` | `DateTime.utc_now/0` |
| `MyApp.Tenant.current/0` | its fallback expression |

No ETS lookup, no branch, no message round-trip. Nested config paths are
resolved straight out of app env with no lookup either. A
[facade](#wrap-it-in-your-own-namespace) adds one `defdelegate` hop on top –
a direct remote call, not a lookup.

### Two gotchas

- **Build releases with `MIX_ENV=prod`.** The flag resolves per `_build` env, so
  a release built with `MIX_ENV=test` carries the machinery. Mix records the
  value in the app manifest, so a release whose runtime config disagrees aborts
  at boot rather than drifting silently.
- **Hard-coding the flag `true` warns** whenever Ambient can tell it's building
  for `:prod`. Derive it from `config_env/0` and the question doesn't arise.

`Ambient.ProcessOverride.enabled?/0` reports the current build.
[Its moduledoc](https://hexdocs.pm/ambient/Ambient.ProcessOverride.html) covers
the rest: what the switch deliberately leaves in place and why, and what
Dialyzer does with a disabled build.

## Enforcing the conventions (optional Credo checks)

Ambient ships two Credo checks that keep direct config and clock reads from
sneaking back in. **They're opt-in**: `credo` is an *optional* dependency, so if
you don't use Credo you pull nothing and the checks aren't even compiled. If you
do, enable them in `.credo.exs`:

```elixir
checks: %{
  extra: [
    {Ambient.Credo.NoDirectConfig, otp_app: :my_app, replacement: "MyApp.Config"},
    {Ambient.Credo.NoDirectClock, replacement: "MyApp.Clock"}
  ]
}
```

`replacement:` is the module name shown in the message, and defaults to
`Ambient.Clock` – so set it to
[your own wrapper](#wrap-it-in-your-own-namespace) or Credo will tell people to
call a module your codebase deliberately doesn't.

`NoDirectConfig` flags runtime `Application.get_env|fetch_env|fetch_env!` for
your app, including the `@otp_app` attribute spelling and piped forms;
`NoDirectClock` flags `DateTime.utc_now/0` & friends and the `:os`/`:erlang`
time primitives, in call and capture forms. Both take `exempt_suffixes:`, a
list of path suffixes to skip.

**A known gap:** the checks match module names as written. A call reached
through an alias (`alias DateTime, as: DT`) or `apply/3` is invisible to them.
In practice the banned calls are written literally; if you rely on the checks
as a hard gate, know that they are a strong convention enforcer rather than a
proof.

## Errors

Misuse raises `Ambient.Error` with a machine-readable `:reason`
(`:overrides_disabled`, `:server_not_started`, `{:not_shared_owner, pid}`,
`:cant_allow_in_shared_mode`, `:not_a_value_module`,
`{:server_start_failed, reason}`) – match on `:reason`, not on message text. A
bad *argument value* (`MyApp.Clock.advance(weeks: 1)`) raises `ArgumentError`
instead: `Ambient.Error` means Ambient is in the wrong state, not that you
passed the wrong term. See [`Ambient.Error`](https://hexdocs.pm/ambient/Ambient.Error.html).

## What it costs to adopt

Honestly: Ambient asks you to change every read site, which puts it on the
dependency-injection side of the "easy to retrofit" line, not the mocking side.
The defence is that the change is **mechanical rather than structural** – swap
`Application.get_env(:my_app, :k)` for `MyApp.Config.get(:k)`, keep the
signature, keep the call graph, and let Credo hold the line – where introducing
launch-time DI means rewiring how components are started.

What that migration doesn't reach, in a codebase of any age:

- `config/runtime.exs` and anything read via `Application.compile_env/3` – both
  resolve before an override can exist;
- timestamps generated by the database (`fragment("now()")`);
- a dependency's own internal `DateTime.utc_now/0`;
- calls the [Credo checks can't see](#enforcing-the-conventions-optional-credo-checks).

So you get a codebase where some reads are overridable and some aren't, and no
compiler help telling them apart. That's a real cost. It's worth paying when
`async: false` is costing you more.

## How it compares

### The patch-based libraries – the closest alternatives

**[Repatch](https://hexdocs.pm/repatch)** patches "any function or macro, Elixir
or Erlang, private or public (except BIF/NIF)", with three modes – `:local`,
`:shared` (the setting process, its spawned tasks and processes passed to
`Repatch.allow/3`, chainable) and `:global`. So it reaches `DateTime.utc_now/0`,
`Application.get_env/3` and `:rand` directly, with the same ownership story
Ambient has, **no wrapper module, no call-site change, no production dependency**
and one `Repatch.setup()` line. For a clock, it is cheaper to adopt than this
library and you should probably use it.

**[Mimic](https://hexdocs.pm/mimic)** is the same idea, narrower: private mode
by default, `Task` processes auto-allowed, `Mimic.copy/1` called from
`test_helper.exs` so nothing touches production, global mode for `async: false`.

**[Patch](https://hexdocs.pm/patch)** is the older, ergonomic one, and the
exception: it recompiles modules and so "alters the global execution
environment", which is why its own docs state "Patch is not compatible with
`async: true`". Convenient, but it takes concurrency off the table.

Where Ambient differs:

| | Patch-based (Repatch / Mimic) | Ambient |
|---|---|---|
| Call sites change | no | yes – you call a wrapper |
| Reaches a dependency's internal `DateTime.utc_now/0` | ✅ | ❌ |
| Seam visible at the call site | no | yes |
| Rewrites modules you don't own | yes | no |
| Keyed and nested config overrides | patch `get_env/3` with a fallthrough clause per key | first-class |

That last row is the reason this library exists. The rest is taste.

### The mocking libraries

- **[Mox](https://hexdocs.pm/mox)** overrides *behaviour* (what a collaborator
  does) against an explicit contract, and is the right tool for that. It's an
  awkward fit for a value read incidentally several layers down: every test
  that transitively touches the clock has to declare it or hit
  `Mox.UnexpectedCallError`, and hoisting a `stub` into a global `setup` is
  this library with more steps. Mox and Ambient are complementary – Ambient
  stays out of mocking.
- **[Klotho](https://hex.pm/packages/klotho)** fakes timers and the clock, but
  its mock is global: it can't be used from tests running in parallel.

### The ownership plumbing

- **[nimble_ownership](https://github.com/dashbitco/nimble_ownership)**
  ([docs](https://hexdocs.pm/nimble_ownership)) solves the same ownership
  problem, is by Dashbit, and is what Mox is built on. If you only need the
  plumbing, it is the more focused library and you should use it. Two
  differences: it keeps state in a GenServer, so reads go through the server
  rather than being direct ETS lookups; and caller inheritance isn't implicit –
  the docs note the server "does not consider the direct and indirect
  'children' of a PID", so you pass `Process.get(:"$callers", [])` yourself.
  Ambient walks that chain for you, then adds the config layer, the Facade, the
  Credo checks and the compile-time switch. The read-path difference is real but
  small – measured at 390ns/op versus 890ns/op under 64-way contention – and it
  only exists in test and dev builds, since production compiles the lookup away.
- **[Ecto.Adapters.SQL.Sandbox](https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Sandbox.html)**
  is the direct inspiration for `allow/3` and shared mode, and the precedent for
  the whole approach.

### The global being replaced

**[Application.put_env/3](https://hexdocs.pm/elixir/Application.html#put_env/4)**
is what `Ambient.Config` exists to replace in tests: it is VM-global, so it is
not safe under `async: true`.

## License

MIT © Mariusz Zak
