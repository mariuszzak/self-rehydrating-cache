defmodule Cache.State do
  @moduledoc false

  @type t :: %__MODULE__{
          store: Agent.agent(),
          task_supervisor: Supervisor.supervisor(),
          registered_functions: %{(key :: any) => pid()},
          workers_supervisor: Supervisor.supervisor(),
          subscribers: %{(key :: any) => [pid()]}
        }

  @enforce_keys [
    :store,
    :task_supervisor,
    :registered_functions,
    :workers_supervisor,
    :subscribers
  ]
  defstruct @enforce_keys
end
