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
  def init(arg) do
    Process.register(self(), arg)
    {:ok, %{boombox_pid: nil, boombox_monitor: nil, last_produced_packet: nil}}
  end

  @impl true
  def handle_call({:run_boombox, run_opts}, _from, state) do
    run_opts =
      [
        input: {:stream, video: :image, audio: false},
        output: "output/index.m3u8"
      ]

    boombox_mode = get_boombox_mode(run_opts)
    gateway_pid = self()

    boombox_process_fun =
      case boombox_mode do
        :consuming -> fn -> consuming_boombox_function(run_opts, gateway_pid) end
        :producing -> fn -> producing_boombox_function(run_opts, gateway_pid) end
      end

    boombox_pid = spawn(boombox_process_fun)
    Process.monitor(boombox_pid)

    last_produced_packet =
      case boombox_mode do
        :consuming ->
          receive do
            :packet_consumed -> nil
          end

        :producing ->
          receive do
            {:packet_produced, packet} -> packet
          end
      end

    {:reply, :ok, %{state | boombox_pid: boombox_pid, last_produced_packet: last_produced_packet}}
  end

  @impl true
  def handle_call({:consume_packet, packet, width, height, timestamp}, _from, state) do
    packet =
      if is_binary(packet) do
        {:ok, img} = Vix.Vips.Image.new_from_binary(packet, width, height, 3, :VIPS_FORMAT_UCHAR)
        %Boombox.Packet{kind: :video, payload: img, pts: Membrane.Time.milliseconds(timestamp)}
      else
        packet
      end

    send(state.boombox_pid, {:consume_packet, packet})

    receive do
      :packet_consumed ->
        {:reply, :ok, state}

      :finished ->
        {:reply, :finished, state}
    end
  end

  @impl true
  def handle_call(:finish_consuming, _from, state) do
    send(state.boombox_pid, :finish_consuming)

    receive do
      :finished ->
        {:reply, :finished, state}
    end
  end

  @impl true
  def handle_call(:produce_packet, _from, state) do
    send(state.boombox_pid, :produce_packet)

    receive do
      {:packet_produced, packet} ->
        {:reply, {:ok, state.last_produced_packet}, %{state | last_produced_packet: packet}}

      :finished ->
        {:reply, {:finished, state.last_produced_packet}, state}
    end
  end

  @impl true
  def handle_info({:call, sender, message}, state) do
    {:reply, reply, state} = handle_call(message, sender, state)
    send(sender, reply)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, :normal}, %{boombox_pid: pid} = state) do
    {:stop, :finished, state}
  end

  @impl true
  def handle_info(info, state) do
    IO.inspect(info)
    {:noreply, state}
  end

  @spec consuming_boombox_function(boombox_opts(), pid()) :: :ok
  defp consuming_boombox_function(run_opts, gateway_pid) do
    Stream.resource(
      fn -> nil end,
      fn nil ->
        send(gateway_pid, :packet_consumed)

        receive do
          {:consume_packet, packet} ->
            {[packet], nil}

          :finish_consuming ->
            {:halt, nil}
        end
      end,
      fn nil -> send(gateway_pid, :finished) end
    )
    |> Boombox.run(run_opts)
  end

  @spec producing_boombox_function(boombox_opts(), pid()) :: :ok
  defp producing_boombox_function(run_opts, gateway_pid) do
    Boombox.run(run_opts)
    |> Enum.each(fn packet ->
      send(gateway_pid, {:packet_produced, packet})

      receive do
        :produce_packet -> :ok
      end
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
