defmodule Cache.Supervisor do
  @moduledoc false
  use Supervisor

  @spec start_link(Keyword.t()) :: GenServer.server()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Cache.Store, name: Cache.Store},
      {Task.Supervisor, name: Cache.TaskSupervisor},
      {Cache, store: Cache.Store, task_supervisor: Cache.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
