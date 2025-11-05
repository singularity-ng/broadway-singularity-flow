defmodule BroadwaySingularityFlow.Pgmq do
  @moduledoc """
  PGMQ integration for Broadway Singularity Flow.

  Provides a standardized interface to PGMQ queues that can be used both
  by the workflow system and external components.
  """

  use Pgmq, repo: BroadwaySingularityFlow.Repo

  @doc """
  Get the configured repo for PGMQ operations.
  """
  def repo do
    Application.get_env(:broadway_singularity_flow, :repo, BroadwaySingularityFlow.Repo)
  end
end