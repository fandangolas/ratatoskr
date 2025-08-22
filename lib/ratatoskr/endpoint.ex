defmodule Ratatoskr.Endpoint do
  @moduledoc """
  gRPC endpoint configuration for Ratatoskr message broker.

  Defines the services available through gRPC and their implementations.
  """

  use GRPC.Endpoint

  run(Ratatoskr.Grpc.Server)
end
