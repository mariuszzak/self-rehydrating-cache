defmodule Cache.State do
  @moduledoc false

  alias Cache.RegisteredFunction

  @type t :: %__MODULE__{
          store: Agent.agent(),
          task_supervisor: Supervisor.supervisor(),
          registered_functions: %{
            (key :: any) => RegisteredFunction.t()
          }
        }

  @enforce_keys [:store, :task_supervisor, :registered_functions]
  defstruct [:store, :task_supervisor, :registered_functions]
end
