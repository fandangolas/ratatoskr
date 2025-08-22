defmodule Ratatoskr.Grpc.MessageBroker.Stub do
  @moduledoc """
  gRPC client stub for MessageBroker service.

  This module provides client functions for interacting with the Ratatoskr
  gRPC server from within the same application (for benchmarking) or from
  external clients.
  """

  use GRPC.Stub, service: Ratatoskr.Grpc.MessageBroker.Service
end
