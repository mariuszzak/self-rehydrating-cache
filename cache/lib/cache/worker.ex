defmodule Cache.Worker do
  @moduledoc false
  use GenServer

  alias Cache.Worker.State

  require Logger

  @type arguments :: [
          fun: (-> {:ok, any()} | {:error, any()}),
          key: any(),
          ttl: non_neg_integer(),
          refresh_interval: non_neg_integer(),
          processing: boolean(),
          task_processor_pid: pid(),
          task_supervisor: Supervisor.supervisor(),
          manager_pid: pid()
        ]

  @spec start_link(arguments()) :: GenServer.on_start()
  def start_link(init_state) do
    GenServer.start_link(__MODULE__, init_state)
  end

  @spec processing_in_progress?(GenServer.server()) :: boolean()
  def processing_in_progress?(worker_pid) do
    GenServer.call(worker_pid, :processing_in_progress)
  end

  @spec update_manager(pid(), pid()) :: :ok
  def update_manager(worker_pid, manager_pid) do
    GenServer.cast(worker_pid, {:update_manager, manager_pid})
  end

  @impl true
  def init(init_state) do
    state = %State{
      fun: init_state.fun,
      key: init_state.key,
      ttl: init_state.ttl,
      refresh_interval: init_state.refresh_interval,
      processing: false,
      task_processor_pid: nil,
      task_supervisor: init_state.task_supervisor,
      manager_pid: init_state.manager_pid
    }

    :ok = register_itself_in_manager(state)

    {:ok, state, {:continue, :schedule_refresh}}
  end

  @impl true
  def handle_call(:processing_in_progress, _from, state) do
    {:reply, state.processing, state}
  end

  @impl true
  def handle_cast({:update_manager, manager_pid}, state) do
    state = %State{state | manager_pid: manager_pid}
    :ok = register_itself_in_manager(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    %State{processing: false} = state
    %Task{pid: task_pid} = execute_function_async(state)

    state = %State{state | processing: true, task_processor_pid: task_pid}

    {:noreply, state}
  end

  # Handles success messages from the TaskSupervisor
  @impl true
  def handle_info({_ref, {:function_processing_finished, key, value}}, state) do
    send(state.manager_pid, {:function_processing_finished, key, value, state.ttl})

    state = %State{state | processing: false, task_processor_pid: nil}

    {:noreply, state, {:continue, :schedule_refresh}}
  end

  # Handles normal task finish from the TaskSupervisor
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  # Handles error messages from the TaskSupervisor
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    state = %State{state | processing: false}

    {:noreply, state, {:continue, :schedule_refresh}}
  end

  @impl true
  def handle_continue(:schedule_refresh, state) do
    Process.send_after(self(), :refresh, state.refresh_interval)
    {:noreply, state}
  end

  defp register_itself_in_manager(state) do
    send(state.manager_pid, {:register_function_worker, state.key, self()})
    :ok
  end

  defp execute_function_async(state) do
    Task.Supervisor.async_nolink(Cache.TaskSupervisor, fn ->
      case state.fun.() do
        {:ok, value} ->
          {:function_processing_finished, state.key, {:ok, value}}

        {:error, error} ->
          Logger.error("Function failed: #{inspect(error)}")
          {:function_processing_finished, state.key, :error}
      end
    end)
  end
end
