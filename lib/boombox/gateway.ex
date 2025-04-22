defmodule Boombox.Gateway do
  use GenServer

  @typep boombox_opts :: [input: Boombox.input(), output: Boombox.output()]
  @typep boombox_mode :: :consuming | :producing | :standalone

  @type packet :: %{
          data: binary(),
          width: pos_integer(),
          height: pos_integer(),
          channels: pos_integer(),
          timestamp: integer()
        }

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
    Process.register(self(), :boombox_gateway)
    {:ok, %{boombox_pid: nil, boombox_monitor: nil, last_produced_packet: nil}}
  end

  @impl true
  def handle_call({:run_boombox, run_opts}, _from, state) do
    boombox_mode = get_boombox_mode(run_opts)
    gateway_pid = self()

    boombox_process_fun =
      case boombox_mode do
        :consuming -> fn -> consuming_boombox_function(run_opts, gateway_pid) end
        :producing -> fn -> producing_boombox_function(run_opts, gateway_pid) end
        :standalone -> fn -> standalone_boombox_function(run_opts) end
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

        :standalone ->
          nil
      end

    {:reply, :ok, %{state | boombox_pid: boombox_pid, last_produced_packet: last_produced_packet}}
  end

  @impl true
  def handle_call(:get_pid, _from, state) do
    {:reply, self(), state}
  end

  @impl true
  def handle_call({:consume_packet, packet}, _from, state) do
    {:ok, img} =
      Vix.Vips.Image.new_from_binary(
        packet.data,
        packet.width,
        packet.height,
        packet.channels,
        :VIPS_FORMAT_UCHAR
      )

    packet =
      %Boombox.Packet{
        kind: :video,
        payload: img,
        pts: Membrane.Time.milliseconds(packet.timestamp)
      }

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

    last_produced_packet = state.last_produced_packet

    {production_phase, state} =
      receive do
        {:packet_produced, packet} -> {:continue, %{state | last_produced_packet: packet}}
        :finished -> {:finished, state}
      end

    output_packet =
      case last_produced_packet.kind do
        :video ->
          {:ok, tensor} = Vix.Vips.Image.write_to_tensor(last_produced_packet.payload)
          {height, width, channels} = tensor.shape

          %{
            data: tensor.data,
            width: width,
            height: height,
            channels: channels,
            timestamp: Membrane.Time.as_milliseconds(last_produced_packet.pts)
          }

        :audio ->
          raise "Not implemented"
      end

    {:reply, {production_phase, output_packet}, state}
  end

  @impl true
  def handle_info({:call, sender, message}, state) do
    {:reply, reply, state} = handle_call(message, sender, state)
    send(sender, reply)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, :normal}, %{boombox_pid: pid} = state) do
    {:stop, :normal, state}
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

  @spec standalone_boombox_function(boombox_opts()) :: :ok
  defp standalone_boombox_function(run_opts) do
    Boombox.run(run_opts)
  end

  @spec get_boombox_mode(input: Boombox.input(), output: Boombox.output()) :: boombox_mode()
  defp get_boombox_mode(run_opts) do
    case Map.new(run_opts) do
      %{input: {:stream, _input_opts}, output: {:stream, _output_opts}} -> raise "Cannot do both"
      %{input: {:stream, _input_opts}} -> :consuming
      %{output: {:stream, _output_opts}} -> :producing
      _neither_input_or_output -> :standalone
    end
  end
end
