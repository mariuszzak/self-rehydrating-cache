defmodule Cache.RegisteredFunction do
  @moduledoc false

  @type t :: %__MODULE__{
          fun: (-> {:ok, any()} | {:error, any()}),
          ttl: non_neg_integer(),
          refresh_interval: non_neg_integer(),
          processing: boolean(),
          task_processing_pid: pid(),
          subscribers: [pid()]
        }

  @enforce_keys [:fun, :ttl, :refresh_interval, :processing, :task_processing_pid, :subscribers]
  defstruct [:fun, :ttl, :refresh_interval, :processing, :task_processing_pid, :subscribers]
end
