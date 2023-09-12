defmodule Cache do
  @moduledoc """
  A periodic self-rehydrating cache. The cache allows to register 0-arity functions (each under a new key)
  that will recompute periodically and store their results in the cache for fast-access instead of being
  called every time the values are needed.

  The Cache server needs to be started together with Cache.Store, Cache.TaskSupervisor and Cache.WorkersSupervisor.
  You can start everything together using `Cache.Supervisor.start_link/1`

  Cache module provides the following functions:
    - `register_function/4`: registers a function that will be computed periodically to update the cache
    - `get/3`: gets the value associated with `key`

  ## Examples

  ```
  iex> ttl = 1_000
  iex> refresh_interval = 100
  iex> function = fn -> {:ok, :cached_value} end
  iex> key = :cached_key
  iex> Cache.register_function(function, key, ttl, refresh_interval)
  :ok
  iex> Process.sleep(refresh_interval + 10)
  iex> Cache.get(key)
  {:ok, :cached_value}
  ```

  """
  use GenServer

  alias Cache.Store
  alias Cache.State
  alias Cache.Worker

  require Logger

  @type result ::
          {:ok, any()}
          | {:error, :timeout}
          | {:error, :not_registered}
          | {:error, :expired}
          | {:error, :not_computed}

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    initial_state = %State{
      registered_functions: %{},
      store: opts[:store] || Store,
      task_supervisor: opts[:task_supervisor] || Cache.TaskSupervisor,
      workers_supervisor: opts[:workers_supervisor] || Cache.WorkersSupervisor,
      subscribers: %{}
    }

    GenServer.start_link(__MODULE__, initial_state, name: opts[:name] || __MODULE__)
  end

  # CLIENT

  @doc ~s"""
  Registers a function that will be computed periodically to update the cache.

  Arguments:
    - `fun`: a 0-arity function that computes the value and returns either
      `{:ok, value}` or `{:error, reason}`.
    - `key`: associated with the function and is used to retrieve the stored
    value.
    - `ttl` ("time to live"): how long (in milliseconds) the value is stored
      before it is discarded if the value is not refreshed.
    - `refresh_interval`: how often (in milliseconds) the function is
      recomputed and the new value stored. `refresh_interval` must be strictly
      smaller than `ttl`. After the value is refreshed, the `ttl` counter is
      restarted.

  The value is stored only if `{:ok, value}` is returned by `fun`. If `{:error,
  reason}` is returned, the value is not stored and `fun` must be retried on
  the next run.
  """
  @spec register_function(
          fun :: (-> {:ok, any()} | {:error, any()}),
          key :: any,
          ttl :: non_neg_integer(),
          refresh_interval :: non_neg_integer()
        ) :: :ok | {:error, :already_registered}
  def register_function(fun, key, ttl, refresh_interval)
      when is_function(fun, 0) and is_integer(ttl) and ttl > 0 and
             is_integer(refresh_interval) and
             refresh_interval < ttl do
    GenServer.call(__MODULE__, {:register_function, fun, key, ttl, refresh_interval})
  end

  @doc ~s"""
  Get the value associated with `key`.

  Details:
    - If the value for `key` is stored in the cache, the value is returned
      immediately.
    - If a recomputation of the function is in progress, the last stored value
      is returned.
    - If the value for `key` is not stored in the cache but a computation of
      the function associated with this `key` is in progress, wait up to
      `timeout` milliseconds. If the value is computed within this interval,
      the value is returned. If the computation does not finish in this
      interval, `{:error, :timeout}` is returned.
    - If `key` is not associated with any function, return `{:error,
      :not_registered}`
  """
  @spec get(any(), non_neg_integer(), Keyword.t()) :: result
  def get(key, timeout \\ 30_000, _opts \\ []) when is_integer(timeout) and timeout > 0 do
    GenServer.cast(__MODULE__, {:get, key, self()})

    receive do
      {:get_response, {:ok, value}} ->
        {:ok, value}

      {:get_response, {:error, :not_registered}} ->
        {:error, :not_registered}

      {:get_response, {:error, :not_computed}} ->
        {:error, :not_computed}

      {:get_response, {:error, :expired}} ->
        {:error, :expired}

      {:get_response, {:error, :processing_in_progress}} ->
        wait_for_function_execution(key, timeout)
    end
  end

  # SERVER

  @impl true
  def init(initial_state) do
    {:ok, initial_state}
  end

  @impl true
  def handle_call({:register_function, fun, key, ttl, refresh_interval}, _from, state) do
    case state.registered_functions do
      %{^key => _} ->
        {:reply, {:error, :already_registered}, state}

      _ ->
        worker_args = %{
          fun: fun,
          key: key,
          ttl: ttl,
          refresh_interval: refresh_interval,
          task_supervisor: state.task_supervisor,
          manager_pid: self()
        }

        {:ok, pid} =
          DynamicSupervisor.start_child(state.workers_supervisor, {Worker, worker_args})

        {:reply, :ok,
         %{state | registered_functions: Map.put(state.registered_functions, key, pid)}}
    end
  end

  defp wait_for_function_execution(key, timeout) do
    receive do
      {:function_processing_finished, ^key, {:ok, value}} ->
        {:ok, value}

      {:function_processing_finished, ^key, :error} ->
        {:error, :not_computed}
    after
      timeout -> {:error, :timeout}
    end
  end

  @impl true
  def handle_cast({:get, key, from}, state) do
    case state.registered_functions do
      %{^key => registered_function_pid} ->
        case Store.get(state.store, key) do
          {:ok, value} ->
            send(from, {:get_response, {:ok, value}})
            {:noreply, state}

          {:error, :not_found} ->
            handle_value_not_found(registered_function_pid, state, from, key)

          {:error, :expired} ->
            send(from, {:get_response, {:error, :expired}})
            {:noreply, state}
        end

      _ ->
        send(from, {:get_response, {:error, :not_registered}})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:function_processing_finished, key, result, ttl}, state) do
    with {:ok, value} <- result, do: :ok = Store.store(state.store, key, value, ttl)

    state
    |> Map.get(:subscribers)
    |> Map.get(key, [])
    |> Enum.each(fn subscriber ->
      send(subscriber, {:function_processing_finished, key, result})
    end)

    {:noreply, state}
  end

  defp handle_value_not_found(registered_function_pid, state, from, key) do
    case Worker.processing_in_progress?(registered_function_pid) do
      true ->
        send(from, {:get_response, {:error, :processing_in_progress}})
        {:noreply, subscribe_caller_to_registered_function(state, key, from)}

      false ->
        send(from, {:get_response, {:error, :not_computed}})
        {:noreply, state}
    end
  end

  defp subscribe_caller_to_registered_function(
         %State{subscribers: subscribers} = state,
         key,
         subscriber
       ) do
    subscribers =
      Map.update(subscribers, key, [subscriber], fn subscribers -> [subscriber | subscribers] end)

    %State{state | subscribers: subscribers}
  end
end
