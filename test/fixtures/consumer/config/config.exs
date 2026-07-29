import Config

# The form the README tells consumers to use.
config :ambient, enable_overrides: config_env() != :prod
