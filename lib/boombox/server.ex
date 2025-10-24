defmodule Boombox.Server do
  @moduledoc false
  # This module provides a GenServer interface for Boombox. To run Boombox the server needs to be
  # called with `{:run, boombox_opts}` - it can be done by calling `run/2`, sending a
  # `{:call, :run, boombox_opts}` message to the server or calling the server directly with
  # `GenServer.call/3`. The return value signals what mode Boombox is in. Once Boombox is running
  # it can be interacted with through appropriate functions, GenServer calls and messages:
  #   * Function calls - `consume_packet/2`, `finish_consuming/1` and `produce_packet/1` are functions
  #                      that can be used for communication with the server.
  #   * GenServer calls - `{:consume_packet, packet}`, `:finish_consuming` and `:produce_packet` are
  #                        terms that the server can be called with. These calls will behave the same
  #                        way as their respective functions mentioned above.
  #   * Messages - `{:call, sender, {:consume_packet, packet}}`, `{:call, sender, :finish_consuming}`
  #                and `{:call, sender, :produce_packet}` messages will cause the server to handle the
  #                call specified by the third element of the tuple and send a `{:response, response}`
  #                tuple to the `sender` when finished.
  # The packets that Boombox is consuming and producing are in the form of
  # `t:serialized_boombox_packet/0` or `t:Boombox.Packet.t/0`, depending on set options.

  use GenServer

  require Logger

  alias Boombox.Packet

  @type t :: pid()

  @type opts :: [
          name: GenServer.name(),
          packet_serialization: boolean(),
          stop_application: boolean()
        ]

  @type boombox_opts :: [
          input: Boombox.input() | {:writer, Boombox.in_raw_data_opts()},
          output: Boombox.output() | {:reader, Boombox.out_raw_data_opts()}
        ]

  @typedoc """
  Mode in which Boombox is operating:
    * `:consuming` - Boombox consumes packets provided with `consume_packet/2` calls,
                     `{:consume_packet, packet}` GenServer calls or receiving
                     `{:call, sender, {:consume_packet, packet}.
    * `:producing` - Boombox produces packets in response to `produce_packet/1` calls,
                     being called directly with `:produce_packet` or receiving
                     `{:call, sender, :produce_packet}` messages.
    * `:standalone` - Boombox neither consumes nor produces packets.
  """
  @type boombox_mode :: :consuming | :producing | :standalone

  @typedoc """
  Serialized audio payload that can be present in a serialized packet.
  Consists of raw data along with audio specific metadata.
  """
  @type serialized_audio_payload :: %{
          data: binary(),
          sample_format: Membrane.RawAudio.SampleFormat.t(),
          sample_rate: pos_integer(),
          channels: pos_integer()
        }

  @typedoc """
  Serialized video payload that can be present in a serialized packet.
  Consists of raw data along with video specific metadata.
  """
  @type serialized_video_payload :: %{
          data: binary(),
          width: pos_integer(),
          height: pos_integer(),
          channels: pos_integer()
        }

  @typedoc """
  Serialized `t:Boombox.Packet.t/0`. Data in this form is sent by the server when demanded from
  and is expected by the server when it demands it.

  This serialization was designed to accomodate constraints set by
  [Pyrlang](https://github.com/Pyrlang/Pyrlang) and to enable interoperability with Python.

  ### Fields
    * `:payload` - record containing either video or audio data.
    * `:timestamp` - timestamp of the packet in milliseconds.
  """
  @type serialized_boombox_packet :: %{
          payload: {:audio, serialized_audio_payload()} | {:video, serialized_video_payload()},
          timestamp: integer()
        }

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            packet_serialization: boolean(),
            stop_application: boolean(),
            boombox_pid: pid() | nil,
            boombox_mode: Boombox.Server.boombox_mode() | nil
          }

    @enforce_keys [:packet_serialization, :stop_application]

    defstruct @enforce_keys ++ [boombox_pid: nil, boombox_mode: nil]
  end

  @doc """
  Starts the server and links it to the current process, for more information see `GenServer.start_link/3`
  """
  @spec start_link(opts()) :: {:ok, t()} | {:error, {:already_started, t()}}
  def start_link(opts) do
    genserver_opts = Keyword.take(opts, [:name])

    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Starts the server, for more information see `GenServer.start/3`
  """
  @spec start(opts()) :: {:ok, t()} | {:error, {:already_started, t()}}
  def start(opts) do
    genserver_opts = Keyword.take(opts, [:name])

    GenServer.start(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Runs Boombox with provided options and enables the usage of other functionalities for communicating
  with it. Availability of different functionalities depends on the mode (`t:boombox_mode/0`) in which
  Boombox is operating.

  All endpoints work the same way as in `Boombox.run/2` with the exception of `:wrtier` and
  `:reader` endpoints. When run with `:writer` input, Boombox will operate in `:consuming`
  mode, and when run with `:reader` output it will operate in `:procuding` mode.
  Otherwise, Boombox will operate in `:standalone` mode.
  """
  @spec run(t(), boombox_opts()) :: boombox_mode()
  def run(server, boombox_opts) do
    GenServer.call(server, {:run, boombox_opts})
  end

  @doc """
  Makes Boombox consume provided packet. Returns `:ok` if more packets can be provided, and
  `:finished` when Boombox finished consuming and will not accept any more packets. Returns
  synchronously once the packet has been processed by Boombox.
  Can be called only when Boombox is in `:consuming` mode.
  """
  @spec consume_packet(t(), serialized_boombox_packet() | Boombox.Packet.t()) ::
          :ok | :finished | {:error, :incompatible_mode}
  def consume_packet(server, packet) do
    GenServer.call(server, {:consume_packet, packet})
  end

  @doc """
  Informs Boombox that it will not be provided any more packets and should terminate
  accordingly.
  Can be called only when Boombox is in `:consuming` mode.
  """
  @spec finish_consuming(t()) :: :finished | {:error, :incompatible_mode}
  def finish_consuming(server) do
    GenServer.call(server, :finish_consuming)
  end

  @doc """
  Requests a packet from Boombox. If returned with `:ok`, then this function can be called
  again to request the next packet, and if returned with `:finished`, then Boombox finished it's
  operation and will not produce any more packets.
  Can be called only when Boombox is in `:producing` mode.
  """
  @spec produce_packet(t()) ::
          {:ok | :finished, serialized_boombox_packet() | Boombox.Packet.t()}
          | {:error, :incompatible_mode}
  def produce_packet(server) do
    GenServer.call(server, :produce_packet)
  end

  @impl true
  def init(opts) do
    {:ok,
     %State{
       packet_serialization: Keyword.get(opts, :packet_serialization, false),
       stop_application: Keyword.get(opts, :stop_application, false)
     }}
  end

  @impl true
  def handle_call(request, _from, state) do
    {response, state} = handle_request(request, state)
    {:reply, response, state}
  end

  @impl true
  def handle_info({:call, sender, request}, state) do
    {response, state} = handle_request(request, state)
    send(sender, {:response, response})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %State{boombox_pid: pid} = state) do
    reason =
      case reason do
        :normal -> :normal
        reason -> {:boombox_crash, reason}
      end

    {:stop, reason, state}
  end

  @impl true
  def handle_info(info, state) do
    Logger.warning("Ignoring message #{inspect(info)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.stop_application do
      # Stop the application after the process terminates, allowing it to exit with the original
      # reason, not :shutdown coming from the top.
      pid = self()

      spawn(fn ->
        Process.monitor(pid)

        receive do
          {:DOWN, _ref, :process, ^pid, ^reason} ->
            Application.stop(:boombox)
        end
      end)
    end
  end

  @spec handle_request({:run, boombox_opts()}, State.t()) :: {boombox_mode(), State.t()}
  defp handle_request({:run, boombox_opts}, state) do
    boombox_mode = get_boombox_mode(boombox_opts)

    boombox_opts =
      boombox_opts
      |> Enum.map(fn
        {direction, {:writer, opts}} -> {direction, {:stream, opts}}
        {direction, {:reader, opts}} -> {direction, {:stream, opts}}
        other -> other
      end)

    server_pid = self()

    boombox_process_fun =
      case boombox_mode do
        :consuming -> fn -> consuming_boombox_run(boombox_opts, server_pid) end
        :producing -> fn -> producing_boombox_run(boombox_opts, server_pid) end
        :standalone -> fn -> standalone_boombox_run(boombox_opts) end
      end

    boombox_pid = spawn(boombox_process_fun)
    Process.monitor(boombox_pid)

    {boombox_mode, %State{state | boombox_pid: boombox_pid, boombox_mode: boombox_mode}}
  end

  @spec handle_request(:get_pid, State.t()) :: {pid(), State.t()}
  defp handle_request(:get_pid, state) do
    {self(), state}
  end

  defp handle_request(_request, %State{boombox_pid: nil} = state) do
    {{:error, :boombox_not_running}, state}
  end

  @spec handle_request(
          {:consume_packet, serialized_boombox_packet() | Boombox.Packet.t()},
          State.t()
        ) ::
          {:ok | :finished | {:error, :incompatible_mode | :boombox_not_running}, State.t()}
  defp handle_request(
         {:consume_packet, packet},
         %State{boombox_mode: :consuming, boombox_pid: boombox_pid} = state
       ) do
    packet =
      if state.packet_serialization do
        deserialize_packet(packet)
      else
        packet
      end

    send(boombox_pid, {:consume_packet, packet})

    receive do
      {:packet_consumed, ^boombox_pid} ->
        {:ok, state}

      {:finished, ^boombox_pid} ->
        {:finished, state}
    end
  end

  defp handle_request({:consume_packet, _packet}, %State{boombox_mode: _other_mode} = state) do
    {{:error, :incompatible_mode}, state}
  end

  @spec handle_request(:finish_consuming, State.t()) ::
          {:finished | {:error, :incompatible_mode | :boombox_not_running}, State.t()}
  defp handle_request(
         :finish_consuming,
         %State{boombox_mode: :consuming, boombox_pid: boombox_pid} = state
       ) do
    send(boombox_pid, :finish_consuming)

    receive do
      {:finished, ^boombox_pid} ->
        {:finished, state}
    end
  end

  defp handle_request(:finish_consuming, %State{boombox_mode: _other_mode} = state) do
    {{:error, :incompatible_mode}, state}
  end

  @spec handle_request(:produce_packet, State.t()) ::
          {{:ok | :finished, serialized_boombox_packet() | Boombox.Packet.t()}
           | {:error, :incompatible_mode | :boombox_not_running}, State.t()}
  defp handle_request(
         :produce_packet,
         %State{boombox_mode: :producing, boombox_pid: boombox_pid} = state
       ) do
    send(boombox_pid, :produce_packet)

    {response_type, packet} =
      receive do
        {:packet_produced, packet, ^boombox_pid} -> {:ok, packet}
        {:finished, packet, ^boombox_pid} -> {:finished, packet}
      end

    packet =
      if state.packet_serialization do
        serialize_packet(packet)
      else
        packet
      end

    {{response_type, packet}, state}
  end

  defp handle_request(:produce_packet, %State{boombox_mode: _other_mode} = state) do
    {{:error, :incompatible_mode}, state}
  end

  @spec handle_request(term(), State.t()) :: {{:error, :invalid_request}, State.t()}
  defp handle_request(_invalid_request, state) do
    {{:error, :invalid_request}, state}
  end

  @spec get_boombox_mode(boombox_opts()) :: boombox_mode()
  defp get_boombox_mode(boombox_opts) do
    case Map.new(boombox_opts) do
      %{input: {:writer, _input_opts}, output: {:reader, _output_opts}} ->
        raise ArgumentError, "using both :reader and :writer is not supported"

      %{input: {:writer, _input_opts}} ->
        :consuming

      %{output: {:reader, _output_opts}} ->
        :producing

      _neither_input_or_output ->
        :standalone
    end
  end

  @spec consuming_boombox_run(boombox_opts(), pid()) :: :ok
  defp consuming_boombox_run(boombox_opts, server_pid) do
    Stream.resource(
      fn -> true end,
      fn is_first_iteration ->
        if not is_first_iteration do
          send(server_pid, {:packet_consumed, self()})
        end

        receive do
          {:consume_packet, packet} ->
            {[packet], false}

          :finish_consuming ->
            {:halt, false}
        end
      end,
      fn _is_first_iteration -> send(server_pid, {:finished, self()}) end
    )
    |> Boombox.run(boombox_opts)
  end

  @spec producing_boombox_run(boombox_opts(), pid()) :: :ok
  defp producing_boombox_run(boombox_opts, server_pid) do
    last_packet =
      Boombox.run(boombox_opts)
      |> Enum.reduce(nil, fn new_packet, last_produced_packet ->
        if last_produced_packet != nil do
          send(server_pid, {:packet_produced, last_produced_packet, self()})
        end

        receive do
          :produce_packet -> :ok
        end

        new_packet
      end)

    send(server_pid, {:finished, last_packet, self()})
  end

  @spec standalone_boombox_run(boombox_opts()) :: :ok
  defp standalone_boombox_run(boombox_opts) do
    Boombox.run(boombox_opts)
  end

  @spec deserialize_packet(serialized_boombox_packet()) :: Packet.t()
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

  @spec serialize_packet(Packet.t()) :: serialized_boombox_packet()
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
end
