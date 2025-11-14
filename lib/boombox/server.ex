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
  #
  # Avaliable actions:
  # write buffer to boombox synchronously
  # write buffer to boombox asynchronously
  # read buffer from boombox synchronously
  # receive buffer from boombox asynchronously (message)
  # close boombox for wrtiting
  # close boombox for reading

  use GenServer

  require Logger

  alias Boombox.Packet

  @type t :: GenServer.server()

  @type communication_medium :: :calls | :messages
  @type flow_control :: :push | :pull

  @type opts :: [
          name: GenServer.name(),
          packet_serialization: boolean(),
          stop_application: boolean(),
          communication_medium: communication_medium()
        ]

  @type boombox_opts :: [
          input: Boombox.input() | {:writer | :message, Boombox.in_raw_data_opts()},
          output: Boombox.output() | {:reader | :message, Boombox.out_raw_data_opts()}
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
            boombox_mode: Boombox.Server.boombox_mode() | nil,
            communication_medium: Boombox.Server.communication_medium(),
            parent_pid: pid(),
            membrane_source_pid: pid() | nil,
            membrane_source_demand: non_neg_integer(),
            membrane_sink_pid: pid() | nil,
            procs: Boombox.Pipeline.procs() | nil,
            pipeline_supervisor_pid: pid() | nil,
            pipeline_pid: pid() | nil,
            ghosted_client: GenServer.from() | pid() | nil,
            limbo_packet: Boombox.Packet.t() | Boombox.Server.serialized_boombox_packet() | nil
          }

    @enforce_keys [
      :packet_serialization,
      :stop_application,
      :communication_medium,
      :parent_pid
    ]

    defstruct @enforce_keys ++
                [
                  boombox_mode: nil,
                  membrane_source_pid: nil,
                  membrane_source_demand: 0,
                  membrane_sink_pid: nil,
                  procs: nil,
                  pipeline_supervisor_pid: nil,
                  pipeline_pid: nil,
                  ghosted_client: nil,
                  limbo_packet: nil
                ]
  end

  @doc """
  Starts the server and links it to the current process, for more information see `GenServer.start_link/3`
  """
  @spec start_link(opts()) :: {:ok, t()} | {:error, {:already_started, t()}}
  def start_link(opts) do
    genserver_opts = Keyword.take(opts, [:name])
    opts = Keyword.put(opts, :parent_pid, self())
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Starts the server, for more information see `GenServer.start/3`
  """
  @spec start(opts()) :: {:ok, t()} | {:error, {:already_started, t()}}
  def start(opts) do
    genserver_opts = Keyword.take(opts, [:name])
    opts = Keyword.put(opts, :parent_pid, self())
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
          {:ok, serialized_boombox_packet() | Boombox.Packet.t()}
          | :finished
          | {:error, :incompatible_mode}
  def produce_packet(server) do
    GenServer.call(server, :produce_packet)
  end

  @doc """
  Informs Boombox that no more packets will be read and shouldn't be produced.
  Can be called only when Boombox is in `:producing` mode.
  """
  @spec finish_producing(t()) :: :finished | {:error, :incompatible_mode}
  def finish_producing(server) do
    GenServer.call(server, :finish_producing)
  end

  @impl true
  def init(opts) do
    {:ok,
     %State{
       packet_serialization: Keyword.get(opts, :packet_serialization, false),
       stop_application: Keyword.get(opts, :stop_application, false),
       communication_medium: Keyword.get(opts, :communication_medium, :calls),
       parent_pid: Keyword.fetch!(opts, :parent_pid)
     }}
  end

  @impl true
  def handle_call(request, from, state) do
    handle_request(request, from, state)
  end

  @impl true
  def handle_info({:call, sender, request}, state) do
    {reply_action, response, state} = handle_request(request, sender, state)

    if reply_action == :reply do
      reply(sender, response)
    end

    {:noreply, state}
  end

  # @impl true
  # def handle_info(
  # {:boombox_packet, sender_pid, %Boombox.Packet{} = packet},
  # %State{communication_medium: :messages} = state
  # ) do
  # {response, state} = handle_request({:consume_packet, packet}, state)
  # if response == :finished, do: send(sender_pid, :boombox_finished)
  # {:noreply, state}
  # end

  @impl true
  def handle_info({:boombox_close, sender_pid}, %State{communication_medium: :messages} = state) do
    handle_request(:finish_consuming, state)
    send(sender_pid, {:boombox_finished, self()})
    {:noreply, state}
  end

  # @impl true
  # def handle_info(
  # {:packet_produced, packet, boombox_pid},
  # %State{communication_medium: :messages, boombox_pid: boombox_pid} = state
  # ) do
  # send(state.parent_pid, {:boombox_packet, self(), packet})
  # {:noreply, state}
  # end

  # @impl true
  # def handle_info(
  # {:finished, packet, boombox_pid},
  # %State{communication_medium: :messages, boombox_pid: boombox_pid} = state
  # ) do
  # send(state.parent_pid, {:boombox_packet, self(), packet})
  # send(state.parent_pid, {:boombox_finished, self()})
  # {:noreply, state}
  # end

  @impl true
  def handle_info({:boombox_elixir_source, source}, state) do
    state =
      if state.ghosted_client != nil do
        send(source, {:boombox_packet, self(), state.limbo_packet})
        reply(state.ghosted_client, :ok)

        %State{state | ghosted_client: nil, limbo_packet: nil}
      else
        state
      end

    {:noreply, %State{state | membrane_source_pid: source}}
  end

  @impl true
  def handle_info({:boombox_elixir_sink, sink}, state) do
    if state.ghosted_client != nil do
      send(sink, {:boombox_demand, self()})
    end

    {:noreply, %State{state | membrane_sink_pid: sink}}
  end

  @impl true
  def handle_info({:boombox_demand, source, demand}, %State{membrane_source_pid: source} = state) do
    state =
      if state.ghosted_client != nil do
        send(state.membrane_source_pid, {:boombox_packet, self(), state.limbo_packet})
        reply(state.ghosted_client, :ok)
        %State{state | ghosted_client: nil, limbo_packet: nil}
      else
        state
      end

    {:noreply, %State{state | membrane_source_demand: state.membrane_source_demand + demand}}
  end

  @impl true
  def handle_info({:boombox_packet, sink, packet}, %State{membrane_sink_pid: sink} = state) do
    if state.ghosted_client != nil do
      packet =
        if state.packet_serialization do
          serialize_packet(packet)
        else
          packet
        end

      reply(state.ghosted_client, {:ok, packet})
      {:noreply, %State{state | ghosted_client: nil}}
    else
      {:noreply, state}
    end
  end

  # @impl true
  # def handle_info({:DOWN, _ref, :process, pid, reason}, %State{boombox_pid: pid} = state) do
  # reason =
  # case reason do
  # :normal -> :normal
  # reason -> {:boombox_crash, reason}
  # end

  # {:stop, reason, state}
  # end

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %State{pipeline_supervisor_pid: pid} = state
      ) do
    if state.ghosted_client != nil do
      GenServer.reply(state.ghosted_client, :finished)
    end

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

  defp handle_request(request, from \\ nil, state)

  @spec handle_request({:run, boombox_opts()}, GenServer.from() | pid() | nil, State.t()) ::
          {:reply, boombox_mode(), State.t()}
  defp handle_request({:run, boombox_opts}, _from, state) do
    boombox_mode = get_boombox_mode(boombox_opts)

    # boombox_opts =
    # boombox_opts
    # |> Enum.map(fn
    # {direction, {:message, opts}} -> {direction, {:stream, opts}}
    # {direction, {:writer, opts}} -> {direction, {:stream, opts}}
    # {direction, {:reader, opts}} -> {direction, {:stream, opts}}
    # other -> other
    # end)

    # server_pid = self()
    procs = Boombox.Pipeline.start_pipeline(Map.new(boombox_opts))
    # procs = %{supervisor: nil, pipeline: nil}

    # boombox_process_fun =
    # state =
    # case boombox_mode do
    # :consuming ->
    # IO.inspect("aaa")

    # receive do
    # {:boombox_elixir_source, source} -> %State{state | membrane_source_pid: source}
    # end

    # IO.inspect(state)

    # :producing ->
    # receive do
    # {:boombox_elixir_sink, sink} -> %State{state | membrane_sink_pid: sink}
    # end

    # :standalone ->
    # state
    # end

    # boombox_pid = spawn(boombox_process_fun)
    # Process.monitor(boombox_pid)

    {:reply, boombox_mode,
     %State{
       state
       | boombox_mode: boombox_mode,
         pipeline_supervisor_pid: procs.supervisor,
         pipeline_pid: procs.pipeline,
         procs: procs
     }}
  end

  @spec handle_request(:get_pid, GenServer.from() | pid() | nil, State.t()) ::
          {:reply, pid(), State.t()}
  defp handle_request(:get_pid, _from, state) do
    {:reply, self(), state}
  end

  defp handle_request(_request, _from, %State{procs: nil} = state) do
    {:reply, {:error, :boombox_not_running}, state}
  end

  @spec handle_request(
          {:consume_packet, serialized_boombox_packet() | Boombox.Packet.t()},
          GenServer.from() | nil,
          State.t()
        ) ::
          {:reply, :ok | :finished | {:error, :incompatible_mode | :boombox_not_running},
           State.t()}
          | {:noreply, State.t()}
  defp handle_request(
         {:consume_packet, packet},
         from,
         %State{boombox_mode: :consuming} = state
       ) do
    packet =
      if state.packet_serialization do
        deserialize_packet(packet)
      else
        packet
      end

    cond do
      state.membrane_source_pid == nil ->
        {:noreply, %State{state | ghosted_client: from, limbo_packet: packet}}

      state.membrane_source_demand == 0 ->
        {:noreply, %State{state | ghosted_client: from, limbo_packet: packet}}

      true ->
        send(state.membrane_source_pid, {:boombox_packet, self(), packet})
        {:reply, :ok, %State{state | membrane_source_demand: state.membrane_source_demand - 1}}
    end

    # if state.membrane_source_demand == 1 do
    # {:noreply, %State{state | membrane_source_demand: 0, ghosted_client: from}}
    # else
    # {:reply, :ok, %State{state | membrane_source_demand: state.membrane_source_demand - 1}}
    # end

    # send(boombox_pid, {:consume_packet, packet})

    # receive do
    # {:packet_consumed, ^boombox_pid} ->
    # {:ok, state}

    # {:finished, ^boombox_pid} ->
    # {:finished, state}
    # end
  end

  defp handle_request(
         {:consume_packet, _packet},
         _from,
         %State{boombox_mode: _other_mode} = state
       ) do
    {:reply, {:error, :incompatible_mode}, state}
  end

  @spec handle_request(:finish_consuming, GenServer.from() | pid() | nil, State.t()) ::
          {:reply, :finished | {:error, :incompatible_mode | :boombox_not_running}, State.t()}
  defp handle_request(
         :finish_consuming,
         from,
         %State{boombox_mode: :consuming} = state
       ) do
    send(state.membrane_source_pid, {:boombox_eos, self()})
    reply(from, :finished)
    Boombox.Pipeline.await_pipeline(state.procs)
    # Boombox.Pipeline.terminate_pipeline(state.procs)
    # send(boombox_pid, :finish_consuming)

    # receive do
    # {:finished, ^boombox_pid} ->
    # {:finished, state}
    # end
    {:noreply, state}
  end

  defp handle_request(:finish_consuming, _from, %State{boombox_mode: _other_mode} = state) do
    {:reply, {:error, :incompatible_mode}, state}
  end

  @spec handle_request(:produce_packet, GenServer.from() | pid() | nil, State.t()) ::
          {:reply, {:error, :incompatible_mode | :boombox_not_running}, State.t()}
          | {:noreply, State.t()}
  defp handle_request(
         :produce_packet,
         from,
         %State{boombox_mode: :producing} = state
       ) do
    if state.membrane_sink_pid != nil do
      send(state.membrane_sink_pid, {:boombox_demand, self()})
    end

    # send(boombox_pid, :produce_packet)

    # {response_type, packet} =
    # receive do
    # {:packet_produced, packet, ^boombox_pid} -> {:ok, packet}
    # {:finished, packet, ^boombox_pid} -> {:finished, packet}
    # end

    # packet =
    # if state.packet_serialization do
    # serialize_packet(packet)
    # else
    # packet
    # end

    # {{response_type, packet}, state}

    {:noreply, %State{state | ghosted_client: from}}
  end

  defp handle_request(:produce_packet, _from, %State{boombox_mode: _other_mode} = state) do
    {:reply, {:error, :incompatible_mode}, state}
  end

  @spec handle_request(:finish_producing, GenServer.from() | pid() | nil, State.t()) ::
          {:reply, :finished | {:error, :incompatible_mode}, State.t()}
  defp handle_request(
         :finish_producing,
         from,
         %State{boombox_mode: :producing} = state
       ) do
    reply(from, :finished)
    Boombox.Pipeline.terminate_pipeline(state.procs)
    # send(boombox_pid, :finish_producing)

    # receive do
    # {:finished, packet, ^boombox_pid} ->
    # {{:finished, packet}, state}
    # end
    {:noreply, :finished, state}
  end

  defp handle_request(:finish_producing, _from, %State{boombox_mode: _other_mode} = state) do
    {:reply, {:error, :incompatible_mode}, state}
  end

  @spec handle_request(term(), GenServer.from() | pid() | nil, State.t()) ::
          {:reply, {:error, :invalid_request}, State.t()}
  defp handle_request(_invalid_request, _from, state) do
    {:reply, {:error, :invalid_request}, state}
  end

  @spec reply(GenServer.from() | pid(), term()) :: :ok
  defp reply(pid, reply_content) when is_pid(pid) do
    send(pid, {:response, reply_content})
  end

  defp reply({pid, _tag} = client, reply_content) when is_pid(pid) do
    GenServer.reply(client, reply_content)
  end

  @spec get_boombox_mode(boombox_opts()) :: boombox_mode()
  defp get_boombox_mode(boombox_opts) do
    cond do
      elixir_endpoint?(boombox_opts[:input]) and elixir_endpoint?(boombox_opts[:output]) ->
        raise ArgumentError, "Using an elixir endpoint on both input and output is not supported"

      elixir_endpoint?(boombox_opts[:input]) ->
        :consuming

      elixir_endpoint?(boombox_opts[:output]) ->
        :producing

      true ->
        :standalone
    end
  end

  defp elixir_endpoint?({type, _opts}) when type in [:stream, :reader, :writer, :message],
    do: true

  defp elixir_endpoint?(_io), do: false

  # @spec consuming_boombox_run(boombox_opts(), pid()) :: :ok
  # defp consuming_boombox_run(boombox_opts, server_pid) do
  # Stream.resource(
  # fn -> true end,
  # fn is_first_iteration ->
  # if not is_first_iteration do
  # send(server_pid, {:packet_consumed, self()})
  # end

  # receive do
  # {:consume_packet, packet} ->
  # {[packet], false}

  # :finish_consuming ->
  # {:halt, false}
  # end
  # end,
  # fn _is_first_iteration -> send(server_pid, {:finished, self()}) end
  # )
  # |> Boombox.run(boombox_opts)
  # end

  # @spec producing_boombox_run(boombox_opts(), pid(), communication_medium()) :: :ok
  # defp producing_boombox_run(boombox_opts, server_pid, communication_medium) do
  # last_packet =
  # Boombox.run(boombox_opts)
  # |> Enum.reduce_while(nil, fn new_packet, last_produced_packet ->
  # if last_produced_packet != nil do
  # send(server_pid, {:packet_produced, last_produced_packet, self()})
  # end

  # action =
  # if communication_medium == :calls do
  # receive do
  # :produce_packet -> :cont
  # :finish_producing -> :halt
  # end
  # else
  # :cont
  # end

  # {action, new_packet}
  # end)

  # send(server_pid, {:finished, last_packet, self()})
  # end

  # @spec standalone_boombox_run(boombox_opts()) :: :ok
  # defp standalone_boombox_run(boombox_opts) do
  # Boombox.run(boombox_opts)
  # end

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
