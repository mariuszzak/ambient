defmodule Ambient.TestConfig do
  @moduledoc false
  # A `use Ambient.Config` consumer bound to the `:ambient` app, for exercising
  # the config layer in this library's own suite.
  use Ambient.Config, otp_app: :ambient
end
