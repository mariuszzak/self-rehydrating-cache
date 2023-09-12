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
