defmodule Cache do
  use GenServer

  alias Cache.RegisteredFunction

  defmodule RegisteredFunction do
    @moduledoc false

    @type t :: %__MODULE__{
            fun: (-> {:ok, any()} | {:error, any()}),
            ttl: non_neg_integer(),
            refresh_interval: non_neg_integer(),
            processing: boolean(),
            subscribers: [pid()]
          }

    @enforce_keys [:fun, :ttl, :refresh_interval, :processing, :subscribers]
    defstruct [:fun, :ttl, :refresh_interval, :processing, :subscribers]
  end

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            store: Agent.server(),
            task_supervisor: Supervisor.supervisor(),
            registered_functions: %{
              (key :: any) => RegisteredFunction.t()
            }
          }

    @enforce_keys [:store, :task_supervisor, :registered_functions]
    defstruct [:store, :task_supervisor, :registered_functions]
  end

  @type result ::
          {:ok, any()}
          | {:error, :timeout}
          | {:error, :not_registered}

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    initial_state = %State{
      registered_functions: %{},
      store: opts[:store] || Cache.Store,
      task_supervisor: opts[:task_supervisor] || Cache.TaskSupervisor
    }

    GenServer.start_link(__MODULE__, initial_state, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(initial_state) do
    {:ok, initial_state}
  end

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

  @impl true
  def handle_call({:register_function, fun, key, ttl, refresh_interval}, _from, state) do
    case state.registered_functions do
      %{^key => _} ->
        {:reply, {:error, :already_registered}, state}

      _ ->
        Process.send_after(self(), {:refresh, key}, refresh_interval)

        {:reply, :ok,
         %{
           state
           | registered_functions:
               Map.put(state.registered_functions, key, %RegisteredFunction{
                 fun: fun,
                 ttl: ttl,
                 refresh_interval: refresh_interval,
                 processing: false,
                 subscribers: []
               })
         }}
    end
  end

  @impl true
  def handle_info({:refresh, key}, state) do
    %RegisteredFunction{processing: false} =
      registered_function = Map.get(state.registered_functions, key)

    registered_function = %RegisteredFunction{registered_function | processing: true}

    execute_function_async(state, key, registered_function)

    {:noreply, update_registered_function(state, key, registered_function)}
  end

  # Handles success messages from the TaskSupervisor
  @impl true
  def handle_info({_ref, {:function_processing_finished, key, value}}, state) do
    registered_function = fetch_registered_function(state, key)

    for subscriber <- registered_function.subscribers do
      send(subscriber, {:function_processing_finished, key, value})
    end

    Process.send_after(self(), {:refresh, key}, registered_function.refresh_interval)

    state =
      update_registered_function(state, key, %RegisteredFunction{
        registered_function
        | processing: false,
          subscribers: []
      })

    {:noreply, state}
  end

  # Handles error messages from the TaskSupervisor
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp execute_function_async(state, key, registered_function) do
    Task.Supervisor.async_nolink(Cache.TaskSupervisor, fn ->
      {:ok, value} = registered_function.fun.()
      :ok = Cache.Store.store(state.store, key, value, registered_function.ttl)
      {:function_processing_finished, key, value}
    end)
  end

  defp fetch_registered_function(%State{registered_functions: registered_functions}, key) do
    Map.get(registered_functions, key)
  end

  defp update_registered_function(
         %State{} = state,
         key,
         %RegisteredFunction{} = registered_function
       ) do
    %State{
      state
      | registered_functions: Map.put(state.registered_functions, key, registered_function)
    }
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

  defp wait_for_function_execution(key, timeout) do
    receive do
      {:function_processing_finished, ^key, value} ->
        {:ok, value}
    after
      timeout -> {:error, :timeout}
    end
  end

  @impl true
  def handle_cast({:get, key, from}, state) do
    case state.registered_functions do
      %{^key => %RegisteredFunction{processing: processing}} ->
        case Cache.Store.get(state.store, key) do
          {:error, :not_found} ->
            if processing do
              send(from, {:get_response, {:error, :processing_in_progress}})
              {:noreply, subscribe_caller_to_registered_function(state, key, from)}
            else
              send(from, {:get_response, {:error, :not_computed}})
              {:noreply, state}
            end

          {:error, :expired} ->
            send(from, {:get_response, {:error, :expired}})
            {:noreply, state}

          {:ok, value} ->
            send(from, {:get_response, {:ok, value}})
            {:noreply, state}
        end

      _ ->
        send(from, {:get_response, {:error, :not_registered}})
        {:noreply, state}
    end
  end

  defp subscribe_caller_to_registered_function(state, key, subscriber) do
    %State{
      state
      | registered_functions:
          Map.put(state.registered_functions, key, %RegisteredFunction{
            state.registered_functions[key]
            | subscribers: [subscriber | state.registered_functions[key].subscribers]
          })
    }
  end
end

defmodule Cache.Store do
  @moduledoc false

  use Agent

  @spec start_link(Keyword.t()) :: Agent.on_start()
  def start_link(opts \\ []) do
    initial_state = %{}
    Agent.start_link(fn -> initial_state end, name: opts[:name] || __MODULE__)
  end

  def store(store, key, value, ttl) when is_integer(ttl) and ttl > 0 do
    current_time = System.monotonic_time(:millisecond)
    expiration_time = current_time + ttl
    Agent.update(store, &Map.put(&1, key, {value, expiration_time}))
  end

  @spec get(pid(), any()) :: {:ok, any} | {:error, :expired | :not_found}
  def get(store, key) do
    current_time = System.monotonic_time(:millisecond)

    case Agent.get(store, &Map.get(&1, key)) do
      {value, expiration_time} when expiration_time > current_time ->
        {:ok, value}

      {_value, _expiration_time} ->
        {:error, :expired}

      nil ->
        {:error, :not_found}
    end
  end
end

defmodule Cache.Supervisor do
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
