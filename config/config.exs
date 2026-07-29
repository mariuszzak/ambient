import Config

# Ambient's own build. Consumers set this in *their* config – Mix ignores a
# dependency's config files, so this line only governs this repo's `_build`.
#
# `:dev` is included so `iex -S mix` and doctests behave like the test suite;
# a `:prod` build (what a consumer's release compiles) gets `false` and has no
# override machinery at all. See `Ambient.ProcessOverride`.
config :ambient, enable_overrides: config_env() != :prod
