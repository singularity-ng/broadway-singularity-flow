defmodule BroadwaySingularityFlow.Repo do
  @moduledoc """
  Ecto repository for Broadway Singularity Flow.

  This repository provides database access for the broadway_singularity_flow application,
  including PGMQ operations and resource management.
  """

  use Ecto.Repo,
    otp_app: :broadway_singularity_flow,
    adapter: Ecto.Adapters.Postgres
end