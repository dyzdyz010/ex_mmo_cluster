defmodule AuthServer.Mailer do
  @moduledoc """
  Auth-side Swoosh mailer wrapper.

  The runtime currently does not center on mail delivery, but keeping this
  wrapper documented avoids leaving unexplained application-facing modules in
  the auth subtree.
  """

  use Swoosh.Mailer, otp_app: :auth_server
end
