defmodule CacheTest do
  use ExUnit.Case

  @default_ttl 1_000

  describe "doc tests" do
    setup do
      start_supervised(Cache.Supervisor)
      :ok
    end

    doctest Cache
  end

  describe "start_link/1" do
    test "starts a GenServer with default options" do
      {:ok, pid} = Cache.start_link()
      assert pid == GenServer.whereis(Cache)
    end

    test "starts a GenServer with custom name option" do
      {:ok, pid} = Cache.start_link(name: :custom_name)
      assert pid == GenServer.whereis(:custom_name)
    end
  end

  describe "register_function/4" do
    setup do
      start_supervised(Cache.Supervisor)
      :ok
    end

    test "registers a function if it is not already registered" do
      assert :ok =
               Cache.register_function(
                 fn -> {:ok, :cached_value} end,
                 :cached_key,
                 @default_ttl,
                 900
               )
    end

    test "does not register a function if it is already registered" do
      assert :ok =
               Cache.register_function(
                 fn -> {:ok, :cached_value} end,
                 :cached_key,
                 @default_ttl,
                 900
               )

      assert {:error, :already_registered} =
               Cache.register_function(
                 fn -> {:ok, :cached_value} end,
                 :cached_key,
                 @default_ttl,
                 900
               )
    end
  end

  describe "get/3" do
    setup do
      start_supervised(Cache.Supervisor)
      :ok
    end

    test "if the value is stored in the cache, it is returned immediately" do
      refresh_interval = 100
      tolerance = 10

      Cache.register_function(
        fn ->
          {:ok, :cached_value}
        end,
        :cached_key,
        @default_ttl,
        refresh_interval
      )

      Process.sleep(refresh_interval + tolerance)

      assert {:ok, :cached_value} = Cache.get(:cached_key)
    end

    test "if `key` is not registered, returns `{:error, :not_registered}`" do
      assert {:error, :not_registered} = Cache.get(:not_registered_key)
    end

    test "if the value for `key` is not stored in the cache" <>
           "and a computation of the function associated with this `key` is in progress" <>
           "and the timeout is reached" <>
           "it returns `{:error, :timeout}`" do
      test_pid = self()

      Cache.register_function(
        fn ->
          send(test_pid, :execution_started)
          Process.sleep(300)
          {:ok, :cached_value}
        end,
        :cached_key,
        @default_ttl,
        100
      )

      assert_receive(:execution_started, 110)
      assert {:error, :timeout} = Cache.get(:cached_key, 200)
    end

    test "if the value for `key` is stored in the cache" <>
           "and a computation of the function associated with this `key` is in progress" <>
           "it returns the last stored value" do
      test_pid = self()

      execution_time = 300
      refresh_interval = 100
      tolerance = 10

      Cache.register_function(
        fn ->
          send(test_pid, :execution_started)
          Process.sleep(execution_time)
          send(test_pid, :execution_finished)
          {:ok, :cached_value}
        end,
        :cached_key,
        @default_ttl,
        refresh_interval
      )

      assert_receive(:execution_finished, execution_time + refresh_interval + tolerance)
      assert_receive(:execution_started, refresh_interval + tolerance)
      Process.sleep(tolerance)
      assert {:ok, :cached_value} = Cache.get(:cached_key, tolerance)
    end

    test "if the value for `key` is not stored in the cache" <>
           "and a computation of the function associated with this `key` is in progress" <>
           "and the timeout is not reached" <>
           "it returns the value" do
      test_pid = self()

      execution_time = 100
      refresh_interval = 200

      Cache.register_function(
        fn ->
          send(test_pid, :execution_started)
          Process.sleep(execution_time)
          {:ok, :cached_value}
        end,
        :cached_key,
        @default_ttl,
        refresh_interval
      )

      assert_receive(:execution_started, refresh_interval + 10)
      assert {:ok, :cached_value} = Cache.get(:cached_key, execution_time + 10)
      refute_received(:execution_started)
    end

    test "multiple get calls at the same time do not block each other" do
      test_pid = self()

      execution_time = 100
      refresh_interval = 200

      Cache.register_function(
        fn ->
          send(test_pid, :execution_started)
          Process.sleep(execution_time)
          {:ok, :cached_value}
        end,
        :cached_key,
        @default_ttl,
        refresh_interval
      )

      assert_receive(:execution_started, refresh_interval + 10)

      time = System.monotonic_time(:millisecond)

      task_1 =
        Task.async(fn ->
          assert {:ok, :cached_value} = Cache.get(:cached_key, execution_time + 10)
        end)

      task_2 =
        Task.async(fn ->
          assert {:ok, :cached_value} = Cache.get(:cached_key, execution_time + 10)
        end)

      task_3 =
        Task.async(fn ->
          assert {:ok, :cached_value} = Cache.get(:cached_key, execution_time + 10)
        end)

      Task.await_many([task_1, task_2, task_3])

      assert System.monotonic_time(:millisecond) - time <= execution_time + 10
    end

    test "if the value for `key` is not stored in the cache" <>
           "and a computation of the function associated with this `key` is not in progress" <>
           "it returns the not_computed error immediately" do
      Cache.register_function(
        fn -> {:ok, :cached_value} end,
        :cached_key,
        999_999,
        999_998
      )

      assert {:error, :not_computed} = Cache.get(:cached_key)
    end

    test "if the value for `key` is in the cache but expired" do
      execution_time = 300

      Cache.register_function(
        fn ->
          Process.sleep(execution_time)
          {:ok, :cached_value}
        end,
        :cached_key,
        200,
        100
      )

      Process.sleep(execution_time * 2 + 10)
      assert {:error, :expired} = Cache.get(:cached_key)
    end

    test "if the function execution crashes it does not affect Cache nor Store" do
      assert ExUnit.CaptureLog.capture_log(fn ->
               Cache.register_function(
                 fn -> {:ok, :value_a} end,
                 :function_a,
                 @default_ttl,
                 100
               )

               Cache.register_function(
                 fn -> raise "super crash" end,
                 :function_b,
                 @default_ttl,
                 10
               )

               Process.sleep(110)

               assert {:ok, :value_a} = Cache.get(:function_a)
             end) =~ "super crash"
    end

    test "functions execute in parallel" do
      assert ExUnit.CaptureLog.capture_log(fn ->
               time = System.monotonic_time(:millisecond)

               refresh_interval = 50
               function_time_execution = 200

               Cache.register_function(
                 fn ->
                   assert System.monotonic_time(:millisecond) - time < refresh_interval + 10
                   Process.sleep(function_time_execution)
                   {:ok, :value_a}
                 end,
                 :function_a,
                 @default_ttl,
                 refresh_interval
               )

               Cache.register_function(
                 fn ->
                   assert System.monotonic_time(:millisecond) - time < refresh_interval + 10
                   Process.sleep(function_time_execution)
                   {:ok, :value_b}
                 end,
                 :function_b,
                 @default_ttl,
                 refresh_interval
               )

               Cache.register_function(
                 fn ->
                   assert System.monotonic_time(:millisecond) - time < refresh_interval + 10
                   Process.sleep(function_time_execution)
                   {:ok, :value_c}
                 end,
                 :function_c,
                 @default_ttl,
                 refresh_interval
               )

               Cache.register_function(
                 fn ->
                   assert System.monotonic_time(:millisecond) - time < refresh_interval + 10
                   raise "crash in function d"
                 end,
                 :function_d,
                 @default_ttl,
                 10
               )

               # Assert that registration of the functions took less than 15ms
               assert System.monotonic_time(:millisecond) - time < 15

               Process.sleep(refresh_interval + function_time_execution + 10)

               assert {:ok, :value_a} = Cache.get(:function_a, 10)
               assert {:ok, :value_b} = Cache.get(:function_b, 10)
               assert {:ok, :value_c} = Cache.get(:function_c, 10)
               assert {:error, :not_computed} = Cache.get(:function_d, 10)
             end) =~ "crash in function d"
    end

    test "function is executed periodically" do
      refresh_interval = 100
      tolerance = 10

      Cache.register_function(
        fn ->
          {:ok, System.monotonic_time(:millisecond)}
        end,
        :cached_key,
        @default_ttl,
        refresh_interval
      )

      Process.sleep(refresh_interval + tolerance)
      assert {:ok, value_a} = Cache.get(:cached_key, tolerance)

      Process.sleep(refresh_interval + tolerance)
      assert {:ok, value_b} = Cache.get(:cached_key, tolerance)

      Process.sleep(refresh_interval + tolerance)
      assert {:ok, value_c} = Cache.get(:cached_key, tolerance)

      assert [value_a, value_b, value_c] |> Enum.uniq() |> length() == 3
    end

    test "function is not executed until the previous execution finishes" do
      test_pid = self()

      execution_time = 200
      refresh_interval = 100

      Cache.register_function(
        fn ->
          send(test_pid, :execution_started)
          Process.sleep(execution_time)
          send(test_pid, :execution_finished)
          {:ok, :cached_value}
        end,
        :cached_key,
        @default_ttl,
        refresh_interval
      )

      # function starts once refresh_interval passes
      assert_receive(:execution_started, refresh_interval + 10)

      # function executes
      refute_receive(:execution_started, execution_time)
      assert_receive(:execution_finished, 10)

      # another function starts once another refresh_interval passes
      refute_receive(:execution_started, refresh_interval)
      assert_receive(:execution_started, 10)
    end

    test "when the function crashes, the next execution is not affected" do
      assert ExUnit.CaptureLog.capture_log(fn ->
               test_pid = self()

               refresh_interval = 100

               time = System.monotonic_time(:millisecond)

               Cache.register_function(
                 fn ->
                   time_passed = System.monotonic_time(:millisecond) - time

                   if time_passed in 0..200 do
                     raise "oops it crashed"
                   end

                   send(test_pid, :function_finished)
                   {:ok, :cached_value}
                 end,
                 :cached_key,
                 @default_ttl,
                 refresh_interval
               )

               assert_receive(:function_finished, refresh_interval * 3)
               Process.sleep(10)
               assert {:ok, :cached_value} = Cache.get(:cached_key)
             end) =~ "oops it crashed"
    end

    test "when the function returns error it does not affect the next executions" do
      assert ExUnit.CaptureLog.capture_log(fn ->
               refresh_interval = 100

               time = System.monotonic_time(:millisecond)

               Cache.register_function(
                 fn ->
                   time_passed = System.monotonic_time(:millisecond) - time

                   if time_passed in 0..200 do
                     {:error, "oops error"}
                   else
                     {:ok, :cached_value}
                   end
                 end,
                 :cached_key,
                 @default_ttl,
                 refresh_interval
               )

               Process.sleep(refresh_interval)
               assert {:error, :not_computed} = Cache.get(:cached_key)
               Process.sleep(refresh_interval + 10)
               assert {:ok, :cached_value} = Cache.get(:cached_key)
             end) =~ "Function failed: \"oops error\""
    end
  end

  describe "worker restart" do
    setup do
      start_supervised(Cache.Supervisor)
      :ok
    end

    test "when a worker restarts it registers itself with a new pid in the manager" do
      refresh_interval = 100

      Cache.register_function(
        fn ->
          {:ok, :cached_value}
        end,
        :cached_key,
        @default_ttl,
        refresh_interval
      )

      Process.sleep(refresh_interval + 10)

      [{_, pid_1, :worker, [Cache.Worker]}] =
        DynamicSupervisor.which_children(Cache.WorkersSupervisor)

      Process.exit(pid_1, :kill)

      Process.monitor(pid_1)

      assert_receive({:DOWN, _ref, :process, ^pid_1, _reason})

      [{_, pid_2, :worker, [Cache.Worker]}] =
        DynamicSupervisor.which_children(Cache.WorkersSupervisor)

      assert pid_2 != pid_1

      assert {:ok, :cached_value} == Cache.get(:cached_key)
    end
  end

  describe "manager restart" do
    setup do
      start_supervised(Cache.Supervisor)
      :ok
    end

    test "when the manager restarts it registers all running workers automatically" do
      refresh_interval = 100

      Cache.register_function(
        fn ->
          {:ok, :cached_value}
        end,
        :cached_key,
        @default_ttl,
        refresh_interval
      )

      Process.sleep(refresh_interval + 10)

      Process.monitor(Cache)
      manager_pid = Process.whereis(Cache)
      Process.exit(manager_pid, :kill)

      assert_receive({:DOWN, _ref, :process, {Cache, :nonode@nohost}, _reason})
      assert manager_pid != Process.whereis(Cache)

      Process.sleep(10)
      assert {:ok, :cached_value} == Cache.get(:cached_key)
    end
  end

  describe "store restart" do
    setup do
      start_supervised(Cache.Supervisor)
      :ok
    end

    test "when the store restarts it flushes all stored values but does not affect other servers" do
      refresh_interval = 100

      Cache.register_function(
        fn ->
          {:ok, :cached_value}
        end,
        :cached_key,
        @default_ttl,
        refresh_interval
      )

      Process.sleep(refresh_interval + 10)

      Process.monitor(Cache.Store)
      store_pid = Process.whereis(Cache.Store)
      Process.exit(store_pid, :kill)

      assert_receive({:DOWN, _ref, :process, {Cache.Store, :nonode@nohost}, _reason})
      assert store_pid != Process.whereis(Cache.Store)

      Process.sleep(10)
      assert {:error, :not_computed} == Cache.get(:cached_key)

      Process.sleep(refresh_interval + 10)

      assert {:ok, :cached_value} == Cache.get(:cached_key)
    end
  end
end
