defmodule Boombox.Server do
  require Logger
  use GenServer

  alias Membrane.RTCP.Packet
  alias Boombox.Packet

  @typep boombox_opts :: [input: Boombox.input(), output: Boombox.output()]
  @typep boombox_mode :: :consuming | :producing | :standalone

  @type serialized_audio_data :: %{
          data: binary(),
          sample_format: Membrane.RawAudio.SampleFormat.t(),
          sample_rate: pos_integer(),
          channels: pos_integer()
        }
  @type serialized_video_data :: %{
          data: binary(),
          width: pos_integer(),
          height: pos_integer(),
          channels: pos_integer()
        }
  @type serialized_packet :: %{
          payload: {:audio, serialized_audio_data()} | {:video, serialized_video_data()},
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
    Process.register(self(), :boombox_server)
    {:ok, %{boombox_pid: nil, boombox_monitor: nil, last_produced_packet: nil}}
  end

  @impl true
  def handle_call({:run_boombox, run_opts}, _from, state) do
    boombox_mode = get_boombox_mode(run_opts)
    server_pid = self()

    boombox_process_fun =
      case boombox_mode do
        :consuming -> fn -> consuming_boombox_function(run_opts, server_pid) end
        :producing -> fn -> producing_boombox_function(run_opts, server_pid) end
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
    packet = deserialize_packet(packet)
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

    serialized_packet = serialize_packet(last_produced_packet)
    {:reply, {production_phase, serialized_packet}, state}
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
    Logger.warning("Ignoring message #{inspect(info)}")
    {:noreply, state}
  end

  @spec deserialize_packet(serialized_packet()) :: Packet.t()
  defp deserialize_packet(%{payload: {:audio, payload}} = serialized_packet) do
    %Boombox.Packet{
      kind: :audio,
      payload: payload.data,
      pts: Membrane.Time.milliseconds(serialized_packet.timestamp),
      format: %{
        audio_format: payload.sample_format,
        audio_rate: payload.sample_rate,
        audio_channels: payload.channels
      }
    }
  end

  defp deserialize_packet(%{payload: {:video, payload}} = serialized_packet) do
    {:ok, img} =
      Vix.Vips.Image.new_from_binary(
        payload.data,
        payload.width,
        payload.height,
        payload.channels,
        :VIPS_FORMAT_UCHAR
      )

    %Boombox.Packet{
      kind: :video,
      payload: img,
      pts: Membrane.Time.milliseconds(serialized_packet.timestamp)
    }
  end

  @spec serialize_packet(Packet.t()) :: serialized_packet()
  defp serialize_packet(%Packet{kind: :audio} = packet) do
    serialized_payload =
      {:audio,
       %{
         data: packet.payload,
         sample_format: packet.format.audio_format,
         sample_rate: packet.format.audio_rate,
         channels: packet.format.audio_channels
       }}

    %{
      payload: serialized_payload,
      timestamp: Membrane.Time.as_milliseconds(packet.pts, :round)
    }
  end

  defp serialize_packet(%Packet{kind: :video} = packet) do
    {:ok, tensor} = Vix.Vips.Image.write_to_tensor(packet.payload)
    {height, width, channels} = tensor.shape

    serialized_payload =
      {:video,
       %{
         data: tensor.data,
         width: width,
         height: height,
         channels: channels
       }}

    %{
      payload: serialized_payload,
      timestamp: Membrane.Time.as_milliseconds(packet.pts, :round)
    }
  end

  @spec consuming_boombox_function(boombox_opts(), pid()) :: :ok
  defp consuming_boombox_function(run_opts, server_pid) do
    Stream.resource(
      fn -> nil end,
      fn nil ->
        send(server_pid, :packet_consumed)

        receive do
          {:consume_packet, packet} ->
            {[packet], nil}

          :finish_consuming ->
            {:halt, nil}
        end
      end,
      fn nil -> send(server_pid, :finished) end
    )
    |> Boombox.run(run_opts)
  end

  @spec producing_boombox_function(boombox_opts(), pid()) :: :ok
  defp producing_boombox_function(run_opts, server_pid) do
    Boombox.run(run_opts)
    |> Enum.each(fn packet ->
      send(server_pid, {:packet_produced, packet})

      receive do
        :produce_packet -> :ok
      end
    end)

    send(server_pid, :finished)
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
