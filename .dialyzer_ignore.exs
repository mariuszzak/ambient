# The compile-time switch (`config :ambient, enable_overrides: …`) is a literal
# by the time these compile, so one arm of each `if @enabled` is constant-folded
# away. That is the entire point – but dialyzer sees a pattern that can never
# match. Every entry here is the switch, not a bug.
[
  # `Ambient.Value`'s `get_or/2` expansion branch and the `writes` spec
  # choice in `__using__/1`.
  {"lib/ambient/value.ex", :pattern_match},
  # The module-body warning for a prod build compiled with the flag on.
  {"lib/ambient/process_override.ex", :pattern_match}
]
