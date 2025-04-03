defmodule Boombox.Gateway do
  use GenServer

  @typep boombox_opts :: [input: Boombox.input(), output: Boombox.output()]
  @typep boombox_mode :: :consuming | :producing

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(arg) do
    GenServer.start_link(__MODULE__, arg)
  end

  @spec start(term()) :: GenServer.on_start()
  def start(arg) do
    GenServer.start(__MODULE__, arg)
  end

  @impl true
  def init(_arg) do
    {:ok, %{boombox_pid: nil, finished: false}}
  end

  @impl true
  def handle_call({:run_boombox, run_opts}, _from, state) do
    boombox_mode = get_boombox_mode(run_opts)
    gateway_pid = self()

    boombox_process_fun =
      case boombox_mode do
        :consuming -> fn -> consuming_boombox_function(run_opts, gateway_pid) end
        :producing -> fn -> producing_boombox_function(run_opts, gateway_pid) end
      end

    boombox_pid = spawn(boombox_process_fun)

    if boombox_mode == :consuming do
      receive do
        :packet_consumed -> :ok
      end
    end

    {:reply, :ok, %{state | boombox_pid: boombox_pid}}
  end

  @impl true
  def handle_call({:consume_packet, packet}, _from, %{finished: false} = state) do
    send(state.boombox_pid, {:consume_packet, packet})

    receive do
      :packet_consumed -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:produce_packet, _from, %{finished: false} = state) do
    send(state.boombox_pid, :produce_packet)

    packet =
      receive do
        {:packet_produced, packet} -> packet
      end

    {:reply, {:ok, packet}, state}
  end

  @impl true
  def handle_info(:finished, state) do
    {:stop, :finished, state}
  end

  @impl true
  def handle_info(info, state) do
    IO.inspect(info)
    {:noreply, state}
  end

  @spec consuming_boombox_function(boombox_opts(), pid()) :: :ok
  defp consuming_boombox_function(run_opts, gateway_pid) do
    Stream.repeatedly(fn ->
      send(gateway_pid, :packet_consumed)

      receive do
        {:consume_packet, packet} -> packet
      end
    end)
    |> Boombox.run(run_opts)

    send(gateway_pid, :finished)
  end

  @spec producing_boombox_function(boombox_opts(), pid()) :: :ok
  defp producing_boombox_function(run_opts, gateway_pid) do
    Boombox.run(run_opts)
    |> Enum.each(fn packet ->
      receive do
        :produce_packet -> :ok
      end

      send(gateway_pid, {:packet_produced, packet})
    end)

    send(gateway_pid, :finished)
  end

  @spec get_boombox_mode(input: Boombox.input(), output: Boombox.output()) :: boombox_mode()
  defp get_boombox_mode(run_opts) do
    case Map.new(run_opts) do
      %{input: {:stream, _input_opts}, output: {:stream, _output_opts}} -> raise "Cannot do both"
      %{input: {:stream, _input_opts}} -> :consuming
      %{output: {:stream, _output_opts}} -> :producing
    end
  end
end
