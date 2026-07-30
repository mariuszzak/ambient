# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-07-29

### Fixed
- **Every `Ambient.Random` read crashed when `Ambient.start_servers/1` hadn't
  been called**, in any build with overrides enabled. `uniform/1`, `bytes/1`,
  `shuffle/1` and friends route through
  `Ambient.ProcessOverride.get_and_update/3`, which reached `shared_owner/1` –
  a bare `:ets.lookup` – before checking the table existed, so ETS raised
  `ArgumentError` ("the table identifier does not refer to an existing ETS
  table") where a read should simply miss and fall through to `:rand`.

  It bit hardest in `:dev`, which the recommended
  `enable_overrides: config_env() != :prod` leaves enabled while nothing
  starts the servers: `iex -S mix` plus any `Ambient.Random` call crashed.
  `Ambient.Clock` and `Ambient.Config` were unaffected – they read through
  `fetch/2`, which has always guarded.

  No table now means no override, so `get_and_update/3` returns `:error` and
  the caller falls through. Writers are unchanged and still raise
  `Ambient.Error` with `:server_not_started`, which is the actionable message
  for the case that really is a mistake.

## [0.1.0] - 2026-07-29

First release.

### Added
- `Ambient.ProcessOverride` – ETS-backed process-local override store with
  `$callers` inheritance and an Ecto-Sandbox-style `allow/3`.
- `Ambient.Clock` – overridable wall clock (`set/1`, `advance/1`, `reset/0`).
- `Ambient.Random` – seedable, replayable RNG (`seed/1`, `uniform`, `shuffle`, …).
- `Ambient.Config` – `use`-able app-config accessor with a per-process override layer.
- `Ambient.start_servers/1` – one-call test setup (runs the servers under
  `Ambient.Supervisor` so a Server crash is restarted + logged, not silent).
- `Ambient.Facade` – `use Ambient.Facade, for: Ambient.Clock` to re-export a
  value module under your own module name, with compile-time-derived delegates.
- Optional Credo checks `Ambient.Credo.NoDirectClock`, `NoDirectRandom` and
  `NoDirectConfig`.
- `config :ambient, enable_overrides: config_env() != :prod` – a compile-time
  switch, **off by default**, that decides whether the override machinery is
  built at all. With it off, `Ambient.start_servers/1`,
  `ProcessOverride.Server.{start_link/1, init/1}`, `put/3` and `allow/3` all
  refuse, so no Ambient API can produce an override.
  `Ambient.ProcessOverride.enabled?/0` reports the build; compiling with the
  flag hard-coded on warns when Ambient can tell it's a prod build.
- `Ambient.Random.bytes/1` now falls through to `:crypto.strong_rand_bytes/1`
  when no seed is in scope, making it **credential-safe in production**: the
  seeded clause isn't compiled into a build that didn't opt in, so no ambient
  seed can downgrade it. It stays deterministic (and non-cryptographic) under
  `seed/1`. The rest of `Ambient.Random` remains `:rand`-backed and must never
  be used for credentials.
- **Shared mode.** `Ambient.set_shared/2` / `Ambient.set_private/1` (and
  `Ambient.ProcessOverride.set_shared/2` / `set_private/1` / `mode/1`) make one
  process's overrides the ones every process reads, for `async: false` tests
  that can't reach a process with `allow/3`. Only the shared owner may write;
  `allow/3` is refused while shared; the owner is monitored, so its exit
  returns the table to private.
- `Ambient.Error` – every Ambient misuse now raises this instead of a bare
  `ArgumentError`/`RuntimeError`, carrying a machine-readable `:reason` and the
  `:table` involved. Bad argument *values* still raise `ArgumentError`.
- `Ambient.Env` – overridable OS environment variables, so tests stop reaching
  for the VM-global `System.put_env/2`. `get/2`, `fetch/1`, `fetch!/1`,
  `put/2`, `put_all/1`, `unset/1` (override as *absent*), `revert/1` (drop the
  override), `reset/0`.
- `Ambient.Value` – the supported extension point. `use Ambient.Value,
  table: :t` generates the writers (`put_override/2`, `delete_override/1`,
  `delete_all/0`, `overridden?/1`, `allow/2`, `set_shared/1`, `set_private/0`,
  `__ambient_table__/0`, all overridable) and imports the `get_or/2` macro. The
  built-ins are built on it.
- `Ambient.Credo.NoDirectEnv` – flags `System.get_env/*` and `System.put_env/*`.
- `Ambient.ProcessOverride.delete_all/1` – drop every override the calling
  process owns in a table.
- `Ambient.ProcessOverride.get_and_update/3` – atomic read-modify-write for
  values whose reads also write, like `Ambient.Random`. A plain `put/3` would
  raise for every non-owner once a table went shared, and a `fetch/2` plus
  `put/3` would lose updates: every process shares one row in shared mode, so
  concurrent draws read the same state and overwrite each other (99 duplicates
  in 200 draws, measured). Shared mode runs the whole operation inside the
  `Server`; private mode stays client-side, where a process can't race itself.

### Fixed
- **`Ambient.Random` was unusable under shared mode.** Every draw writes its
  advanced state back, and shared mode forbids non-owner writes, so any process
  that wasn't the shared owner raised `{:not_shared_owner, pid}` – i.e. exactly
  the processes shared mode exists to reach. Writes now route through
  `get_and_update/3`, giving one globally advancing stream.
- **`allow/3` and `set_shared/2` monitored by cast, then inserted from the
  client**, so a pid dying in the gap left a row no `:DOWN` would ever clean.
  Measured over 40k attempts: 202 orphaned `allow` rows (which pid reuse then
  hands to an unrelated process – a leak in the library whose promise is no
  leaks) and 146 tables stuck shared to a dead pid, where every write raises
  until someone calls `set_private/1`. Both now monitor and insert inside the
  Server, on the same side of its mailbox as the `:DOWN`. Reproduced at 0 after.
- **`Ambient.Supervisor` used the default 3-restarts-in-5-seconds and stayed
  linked to whichever process called `start_servers/1` first.** A suite that
  restarts a Server (or `--repeat-until-failure`) exhausted it, and the
  supervisor's exit took every override table and the test run with it.
- **A non-owner could silently steal or cancel shared mode.** `set_shared/2`
  now raises `{:not_shared_owner, pid}` when the table is already shared by
  someone else. `set_private/1` stays open deliberately – `on_exit/1` runs in a
  different process from the test.
- **All four Credo checks missed piped calls** when the banned entry pinned an
  exact arity: a pipe leaves the receiver out of the call node, so
  `list |> Enum.shuffle()` – the form almost everyone writes – slipped past
  `NoDirectRandom` entirely.
- `Ambient.Value`'s `defoverridable` list omitted `__ambient_table__/0`, so
  redefining it only produced a "clause cannot match" warning while the
  generated one silently won.
- `Ambient.Facade` now passes `__ambient_table__/0` through, so a facade can be
  given to `Ambient.start_servers/1` and `set_shared/2` in place of the value module
  it wraps. It was rejected as `:not_a_value_module`.
- `Ambient.Random.normal/2`'s second argument was documented as the standard
  deviation; like `:rand.normal_s/3`, it is the **variance**.

### Changed
- `use Ambient.Config` now generates the domain verbs the other values have:
  `put/2`, `revert/1` and `reset/0`, alongside `get/2`. It was the only value module
  whose documented API was the raw `Ambient.Value` layer.
- `Ambient.start_servers/1`, `set_shared/2` and `set_private/1` accept a single
  value module as well as a list, so they no longer collide by argument shape with
  the same-named `Ambient.ProcessOverride` functions that take one raw table.
  A non-atom, non-list argument now raises `Ambient.Error` with
  `:not_a_value_module` instead of `FunctionClauseError`.
- **Production wrappers are now free.** `get_or/2` expands at compile time, so
  in a build without overrides each wrapper compiles to exactly the function it
  wraps: `Ambient.Clock.utc_now/0` to `DateTime.utc_now/0`, a generated
  `MyApp.Config.get/2` to `Application.get_env/3`, `Ambient.Env.get/2` to
  `System.get_env/2`. `Ambient.Clock` and `Ambient.Config` previously paid one
  `:ets.whereis/1` per call.
- **`Ambient.Random`'s unseeded path no longer reseeds per call.** It built a
  fresh `:rand.seed_s(:exsss)` on every call, ~12x the cost of the plain `:rand`
  function; it now delegates to `:rand.uniform/1` and friends, which seed the
  process dictionary once. Seeded behaviour is unchanged.
- `Ambient.Clock.utc_now/0` no longer re-checks that the stored override is a
  `DateTime` – `set/1` is the only writer and is typed.

### Upgrading from the git dependency

Only relevant if you tracked `main` before this release.

Add the switch to `config/config.exs` – without it `Ambient.start_servers/1`
raises and your suite won't boot:

```elixir
config :ambient, enable_overrides: config_env() != :prod
```

Derive it from `config_env/0` rather than hard-coding `true`; that's what keeps
the machinery – and the only way to downgrade `Random.bytes/1` – out of your
release. Prefer `!= :prod` over `== :test`: Dialyzer runs in `:dev`, and in a
disabled build the writers raise, so gating on `== :test` makes it report every
generated writer in your own modules as having no local return.

Also:

- If you rescue Ambient's exceptions, switch from `ArgumentError` to
  `Ambient.Error` and match on `:reason`.
- `Ambient.start_servers/1` now raises `:not_a_value_module` for a module-looking
  atom that doesn't export `__ambient_table__/0`, where it previously accepted
  it as a raw table name. Facades are fine – they now pass it through.
- Unseeded `Ambient.Random.bytes/1` changed source, from a `:rand` stream to
  `:crypto.strong_rand_bytes/1`. Output shape is identical; it is simply no
  longer predictable from a `:rand` seed.
- Unseeded `Ambient.Random` now draws from the process dictionary's `:rand`
  state rather than a fresh one per call, so a caller who seeded `:rand`
  directly will see those draws follow that seed.

[0.1.1]: https://github.com/mariuszzak/ambient/releases/tag/v0.1.1
[0.1.0]: https://github.com/mariuszzak/ambient/releases/tag/v0.1.0
