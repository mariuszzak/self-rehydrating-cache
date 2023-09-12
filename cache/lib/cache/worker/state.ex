defmodule Cache.Worker.State do
  @moduledoc false

  @type t :: %__MODULE__{
          fun: (-> {:ok, any()} | {:error, any()}),
          key: any(),
          ttl: non_neg_integer(),
          refresh_interval: non_neg_integer(),
          processing: boolean(),
          task_processing_pid: pid(),
          task_supervisor: Supervisor.supervisor(),
          manager_pid: pid()
        }

  @enforce_keys [
    :fun,
    :key,
    :ttl,
    :refresh_interval,
    :processing,
    :task_processing_pid,
    :task_supervisor,
    :manager_pid
  ]
  defstruct @enforce_keys
end
