defmodule Converger.Repo do
  use Ecto.Repo,
    otp_app: :converger,
    adapter: Ecto.Adapters.Postgres
end
