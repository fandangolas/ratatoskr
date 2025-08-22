defmodule Ratatoskr.Grpc.CreateTopicRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:name, 1, type: :string)
end

defmodule Ratatoskr.Grpc.CreateTopicResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:topic, 1, type: :string)
  field(:created, 2, type: :bool)
  field(:error, 3, type: :string)
end

defmodule Ratatoskr.Grpc.DeleteTopicRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:name, 1, type: :string)
end

defmodule Ratatoskr.Grpc.DeleteTopicResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:success, 1, type: :bool)
  field(:error, 2, type: :string)
end

defmodule Ratatoskr.Grpc.ListTopicsRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3
end

defmodule Ratatoskr.Grpc.ListTopicsResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:topics, 1, repeated: true, type: :string)
end

defmodule Ratatoskr.Grpc.TopicExistsRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:name, 1, type: :string)
end

defmodule Ratatoskr.Grpc.TopicExistsResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:exists, 1, type: :bool)
end

defmodule Ratatoskr.Grpc.GetStatsRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:topic, 1, type: :string)
end

defmodule Ratatoskr.Grpc.GetStatsResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:topic, 1, type: :string)
  field(:message_count, 2, type: :int64)
  field(:subscriber_count, 3, type: :int32)
  field(:error, 4, type: :string)
end

defmodule Ratatoskr.Grpc.PublishRequest.MetadataEntry do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Ratatoskr.Grpc.PublishRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:topic, 1, type: :string)
  field(:payload, 2, type: :bytes)

  field(:metadata, 3,
    repeated: true,
    type: Ratatoskr.Grpc.PublishRequest.MetadataEntry,
    map: true
  )
end

defmodule Ratatoskr.Grpc.PublishResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:message_id, 1, type: :string)
  field(:timestamp, 2, type: :int64)
  field(:success, 3, type: :bool)
  field(:error, 4, type: :string)
end

defmodule Ratatoskr.Grpc.PublishBatchRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:topic, 1, type: :string)
  field(:messages, 2, repeated: true, type: Ratatoskr.Grpc.PublishRequest)
end

defmodule Ratatoskr.Grpc.PublishBatchResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:results, 1, repeated: true, type: Ratatoskr.Grpc.PublishResponse)
  field(:success_count, 2, type: :int32)
  field(:error_count, 3, type: :int32)
end

defmodule Ratatoskr.Grpc.SubscribeRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:topic, 1, type: :string)
  field(:subscriber_id, 2, type: :string)
end

defmodule Ratatoskr.Grpc.UnsubscribeRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:topic, 1, type: :string)
  field(:subscription_ref, 2, type: :string)
end

defmodule Ratatoskr.Grpc.UnsubscribeResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:success, 1, type: :bool)
  field(:error, 2, type: :string)
end

defmodule Ratatoskr.Grpc.Message.MetadataEntry do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Ratatoskr.Grpc.Message do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:id, 1, type: :string)
  field(:topic, 2, type: :string)
  field(:payload, 3, type: :bytes)
  field(:metadata, 4, repeated: true, type: Ratatoskr.Grpc.Message.MetadataEntry, map: true)
  field(:timestamp, 5, type: :int64)
end

defmodule Ratatoskr.Grpc.AckRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:message_id, 1, type: :string)
  field(:success, 2, type: :bool)
end

defmodule Ratatoskr.Grpc.AckResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.12.0", syntax: :proto3

  field(:acknowledged, 1, type: :bool)
end

defmodule Ratatoskr.Grpc.MessageBroker.Service do
  @moduledoc false

  use GRPC.Service, name: "ratatoskr.MessageBroker", protoc_gen_elixir_version: "0.12.0"

  rpc(:CreateTopic, Ratatoskr.Grpc.CreateTopicRequest, Ratatoskr.Grpc.CreateTopicResponse)

  rpc(:DeleteTopic, Ratatoskr.Grpc.DeleteTopicRequest, Ratatoskr.Grpc.DeleteTopicResponse)

  rpc(:ListTopics, Ratatoskr.Grpc.ListTopicsRequest, Ratatoskr.Grpc.ListTopicsResponse)

  rpc(:TopicExists, Ratatoskr.Grpc.TopicExistsRequest, Ratatoskr.Grpc.TopicExistsResponse)

  rpc(:GetStats, Ratatoskr.Grpc.GetStatsRequest, Ratatoskr.Grpc.GetStatsResponse)

  rpc(:Publish, Ratatoskr.Grpc.PublishRequest, Ratatoskr.Grpc.PublishResponse)

  rpc(:PublishBatch, Ratatoskr.Grpc.PublishBatchRequest, Ratatoskr.Grpc.PublishBatchResponse)

  rpc(:Subscribe, Ratatoskr.Grpc.SubscribeRequest, stream(Ratatoskr.Grpc.Message))

  rpc(:Unsubscribe, Ratatoskr.Grpc.UnsubscribeRequest, Ratatoskr.Grpc.UnsubscribeResponse)
end
