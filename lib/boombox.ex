defmodule Boombox do
  @moduledoc """
  Boombox is a tool for audio and video streaming.

  See `run/1` for details and [examples.livemd](examples.livemd) for examples.
  """

  require Logger
  require Membrane.Time
  require Membrane.Transcoder.{Audio, Video}

  alias Membrane.HTTPAdaptiveStream
  alias Membrane.RTP

  defmodule Writer do
    @moduledoc """
    Defines a struct to be used when interacting with boombox when using `:writer` endpoint.
    """
    @opaque t :: %__MODULE__{
              server_reference: GenServer.server()
            }

    @enforce_keys [:server_reference]
    defstruct @enforce_keys
  end

  defmodule Reader do
    @moduledoc """
    Defines a struct to be used when interacting with boombox when using `:reader` endpoint.
    """
    @opaque t :: %__MODULE__{
              server_reference: GenServer.server()
            }

    @enforce_keys [:server_reference]
    defstruct @enforce_keys
  end

  @opaque boombox_server :: Boombox.Server.t()

  @type transcoding_policy_opt :: {:transcoding_policy, :always | :if_needed | :never}
  @typedoc """
  If true the incoming streams will be passed to the output according to their
  timestamps, if not they will be passed as fast as possible. True by default.
  """
  @type pace_control_opt :: {:pace_control, boolean()}
  @type hls_mode_opt :: {:mode, :live | :vod}
  @type hls_variant_selection_policy_opt ::
          {:variant_selection_policy, HTTPAdaptiveStream.Source.variant_selection_policy()}

  @type webrtc_signaling :: Membrane.WebRTC.Signaling.t() | String.t()
  @type srt_auth_opts :: [
          {:stream_id, String.t()}
          | {:password, String.t()}
        ]
  @type in_raw_data_opts :: [
          {:audio, :binary | boolean()}
          | {:video, :image | boolean()}
          | {:is_live, boolean()}
        ]
  @type out_raw_data_opts :: [
          {:audio, :binary | boolean()}
          | {:video, :image | boolean()}
          | {:audio_format, Membrane.RawAudio.SampleFormat.t()}
          | {:audio_rate, Membrane.RawAudio.sample_rate_t()}
          | {:audio_channels, Membrane.RawAudio.channels_t()}
          | {:video_width, non_neg_integer()}
          | {:video_height, non_neg_integer()}
          | pace_control_opt()
        ]

  @typedoc """
  When configuring a track for a media type (video or audio), the following options are used:
    * <media_type>_encoding - MUST be provided to configure given media type. Some options are encoding-specific. Currently supported encodings are: AAC, Opus, H264, H265.
    * <media_type>_payload_type, <media_type>_clock rate - MAY be provided. If not, an unofficial default will be used.
  The following encoding-specific parameters are available for both RTP input and output:
    * aac_bitrate_mode - MUST be provided for AAC encoding. Defines which mode should be assumed/set when depayloading/payloading.
  """
  @type common_rtp_opt ::
          {:video_encoding, RTP.encoding_name()}
          | {:video_payload_type, RTP.payload_type()}
          | {:video_clock_rate, RTP.clock_rate()}
          | {:audio_encoding, RTP.encoding_name()}
          | {:audio_payload_type, RTP.payload_type()}
          | {:audio_clock_rate, RTP.clock_rate()}
          | {:aac_bitrate_mode, RTP.AAC.Utils.mode()}

  @typedoc """
  In order to configure a RTP input a receiving port MUST be provided and the media that will be received
  MUST be configured. Media configuration is explained further in `t:common_rtp_opt/0`.

  The following encoding-specific parameters are available for RTP input:
    * audio_specific_config - MUST be provided for AAC encoding. Contains crucial information about the stream and has to be obtained from a side channel.
    * vps (H265 only), pps, sps - MAY be provided for H264 or H265 encodings. Parameter sets, could be obtained from a side channel. They contain information about the encoded stream.
  """
  @type in_rtp_opts :: [
          common_rtp_opt()
          | {:port, :inet.port_number()}
          | {:audio_specific_config, binary()}
          | {:vps, binary()}
          | {:pps, binary()}
          | {:sps, binary()}
        ]

  @typedoc """
  In order to configure a RTP output the target port and address MUST be provided (can be provided in `:target` option as a `<address>:<port>` string)
  and the media that will be sent MUST be configured. Media configuration is explained further in `t:common_rtp_opt/0`.
  """
  @type out_rtp_opts :: [
          common_rtp_opt()
          | {:address, :inet.ip_address() | String.t()}
          | {:port, :inet.port_number()}
          | {:target, String.t()}
          | transcoding_policy_opt()
        ]

  @type input ::
          (path_or_uri :: String.t())
          | {path_or_uri :: String.t(),
             [hls_variant_selection_policy_opt()]
             | [{:framerate, Membrane.H264.framerate() | Membrane.H265.framerate_t()}]}
          | {:mp4 | :aac | :wav | :mp3 | :ivf | :ogg | :h264 | :h265, location :: String.t()}
          | {:mp4 | :aac | :wav | :mp3 | :ivf | :ogg, location :: String.t(),
             transport: :file | :http}
          | {:h264, location :: String.t(),
             transport: :file | :http, framerate: Membrane.H264.framerate()}
          | {:h265, location :: String.t(),
             transport: :file | :http, framerate: Membrane.H265.framerate_t()}
          | {:webrtc, webrtc_signaling()}
          | {:whip, uri :: String.t(), token: String.t()}
          | {:rtmp, (uri :: String.t()) | (client_handler :: pid)}
          | {:rtsp, url :: String.t()}
          | {:rtp, in_rtp_opts()}
          | {:hls, url :: String.t()}
          | {:hls, url :: String.t(), [hls_variant_selection_policy_opt()]}
          | {:srt, url :: String.t()}
          | {:srt, url :: String.t(), srt_auth_opts()}
          | {:srt, server_awaiting_accept :: ExLibSRT.Server.t()}

  @type elixir_input :: {:stream | :writer | :message, in_raw_data_opts()}

  @type output ::
          (path_or_uri :: String.t())
          | {path_or_uri :: String.t(), [transcoding_policy_opt() | hls_mode_opt()]}
          | {:mp4 | :aac | :wav | :mp3 | :ivf | :ogg | :h264 | :h265, location :: String.t()}
          | {:mp4 | :aac | :wav | :mp3 | :ivf | :ogg | :h264 | :h265, location :: String.t(),
             [transcoding_policy_opt()]}
          | {:webrtc, webrtc_signaling()}
          | {:webrtc, webrtc_signaling(), [transcoding_policy_opt()]}
          | {:whip, uri :: String.t(),
             [{:token, String.t()} | {bandit_option :: atom(), term()} | transcoding_policy_opt()]}
          | {:hls, location :: String.t()}
          | {:hls, location :: String.t(), [hls_mode_opt() | transcoding_policy_opt()]}
          | {:rtp, out_rtp_opts()}
          | {:srt, url :: String.t()}
          | {:srt, url :: String.t(), srt_auth_opts()}
          | :player

  @type elixir_output :: {:stream | :reader | :message, out_raw_data_opts()}

  @typep procs :: %{pipeline: pid(), supervisor: pid()}
  @typep opts_map :: %{
           input: input() | elixir_input(),
           output: output() | elixir_output(),
           parent: pid()
         }

  @doc """
  Runs boombox with given input and output.

  ## Example

  ```
  Boombox.run(input: "rtmp://localhost:5432", output: "index.m3u8")
  ```

  See `t:input/0` and `t:output/0` for available inputs and outputs and
  [examples.livemd](examples.livemd) for examples.

  If the input is a `:stream` endpoint, a `Stream` or other `Enumerable` is expected
  as the first argument.

  If the input is a `:writer` endpoint this function will return a `Boombox.Writer` struct,
  which is used to write media packets to boombox with `write/2` and to finish writing with `close/1`.

  If the output is a `:reader` endpoint this function will return a `Boombox.Reader` struct,
  which is used to read media packets from boombox with `read/1`.

  ```
  Boombox.run(
    input: "path/to/file.mp4",
    output: {:webrtc, "ws://0.0.0.0:1234"}
  )
  ```
  """
  @spec run(Enumerable.t() | nil,
          input: input() | elixir_input(),
          output: output() | elixir_output()
        ) :: :ok | Enumerable.t() | Writer.t() | Reader.t()
  def run(stream \\ nil, opts) do
    opts = validate_opts!(stream, opts)

    case opts do
      %{input: {:stream, _stream_opts}} ->
        procs = start_pipeline(opts)
        source = await_source_ready()
        consume_stream(stream, source, procs)

      %{output: {:stream, _stream_opts}} ->
        procs = start_pipeline(opts)
        sink = await_sink_ready()
        produce_stream(sink, procs)

      %{input: {:writer, _writer_opts}} ->
        pid = start_server(opts, :calls)
        %Writer{server_reference: pid}

      %{input: {:message, _message_opts}} ->
        start_server(opts, :messages)

      %{output: {:reader, _reader_opts}} ->
        pid = start_server(opts, :calls)
        %Reader{server_reference: pid}

      %{output: {:message, _message_opts}} ->
        start_server(opts, :messages)

      opts ->
        opts
        |> start_pipeline()
        |> await_pipeline()
    end
  end

  @doc """
  Runs boombox with given input and plays audio and video streams on your computer.

  `Boombox.play(input)` is idiomatic to `Boombox.run(input: input, output: :player)`.

  ## Example

  ```
  Boombox.play("rtmp://localhost:5432")
  ```
  """
  @spec play(Enumerable.t() | nil, input() | elixir_input()) :: :ok
  def play(stream \\ nil, input) do
    stream |> run(input: input, output: :player)
  end

  @doc """
  Asynchronous version of `run/2`.

  Doesn't block the calling process until the termination of the processing.

  It returns a `Task.t()` that can be awaited later.

  If the output is a `:stream` or `:reader` endpoint, or the input is a `:writer` endpoint,
  the behaviour is identical to `run/2`.
  """
  @spec async(Enumerable.t() | nil,
          input: input(),
          output: output()
        ) :: Task.t() | Enumerable.t()
  def async(stream \\ nil, opts) do
    opts = validate_opts!(stream, opts)

    case opts do
      %{input: {:stream, _stream_opts}} ->
        procs = start_pipeline(opts)
        source = await_source_ready()

        Task.async(fn ->
          Process.monitor(procs.supervisor)
          consume_stream(stream, source, procs)
        end)

      %{output: {:stream, _stream_opts}} ->
        procs = start_pipeline(opts)
        sink = await_sink_ready()
        produce_stream(sink, procs)

      %{input: {:writer, _writer_opts}} ->
        pid = start_server(opts, :calls)
        %Writer{server_reference: pid}

      %{input: {:message, _message_opts}} ->
        start_server(opts, :messages)

      %{output: {:reader, _reader_opts}} ->
        pid = start_server(opts, :calls)
        %Reader{server_reference: pid}

      %{output: {:message, _message_opts}} ->
        start_server(opts, :messages)

      # In case of rtmp, rtmps, rtp, rtsp, we need to wait for the tcp/udp server to be ready
      # before returning from async/2.
      %{input: {protocol, _opts}} when protocol in [:rtmp, :rtmps, :rtp, :rtsp, :srt] ->
        procs = start_pipeline(opts)

        task =
          Task.async(fn ->
            Process.monitor(procs.supervisor)
            await_pipeline(procs)
          end)

        await_external_resource_ready()
        task

      opts ->
        procs = start_pipeline(opts)

        Task.async(fn ->
          Process.monitor(procs.supervisor)
          await_pipeline(procs)
        end)
    end
  end

  @doc """
  Runs boombox with CLI arguments.

  ## Example
  ```
  # boombox.exs
  Mix.install([:boombox])
  Boombox.run_cli()
  ```

  ```sh
  elixir boombox.exs -i "rtmp://localhost:5432" -o "index.m3u8"
  ```
  """
  @spec run_cli([String.t()]) :: :ok
  def run_cli(argv \\ System.argv()) do
    case Boombox.Utils.CLI.parse_argv(argv) do
      {:args, args} -> run(args)
      {:script, script} -> Code.eval_file(script)
    end
  end

  @doc """
  Reads a packet from Boombox.

  If returned with `:ok`, then this function can be called
  again to request the next packet, and if returned with `:finished`, then Boombox finished it's
  operation and will not produce any more packets.

  Can be called only when using `:reader` endpoint on output.
  """
  @spec read(Reader.t()) ::
          {:ok | :finished, Boombox.Packet.t()} | {:error, :incompatible_mode}
  def read(reader) do
    Boombox.Server.produce_packet(reader.server_reference)
  end

  @doc """
  Writes provided packet to Boombox.

  Returns `:ok` if more packets can be provided, and
  `:finished` when Boombox finished consuming and will not accept any more packets. Returns
  synchronously once the packet has been processed by Boombox.

  Can be called only when using `:writer` endpoint on input.
  """
  @spec write(Writer.t(), Boombox.Packet.t()) ::
          :ok | :finished | {:error, :incompatible_mode}
  def write(writer, packet) do
    Boombox.Server.consume_packet(writer.server_reference, packet)
  end

  @doc """
  Informs Boombox that it will not be provided any more packets with `write/2` and should terminate
  accordingly.

  Can be called only when using `:writer` endpoint on input.
  """
  @spec close(Writer.t()) :: :finished | {:error, :incompatible_mode}
  def close(writer) do
    Boombox.Server.finish_consuming(writer.server_reference)
  end

  @endpoint_opts [:input, :output]
  defp validate_opts!(stream, opts) do
    opts = opts |> Keyword.validate!(@endpoint_opts) |> Map.new()

    cond do
      Map.keys(opts) -- @endpoint_opts != [] ->
        raise ArgumentError,
              "Both input and output are required. #{@endpoint_opts -- Map.keys(opts)} were not provided"

      match?({:stream, _opts}, opts.input) && !Enumerable.impl_for(stream) ->
        raise ArgumentError,
              "Expected Enumerable.t() to be passed as the first argument, got #{inspect(stream)}"

      elixir_endpoint?(opts.input) and elixir_endpoint?(opts.output) ->
        raise ArgumentError,
              "Using an elixir endpoint (:reader, :writer, :message, :stream) on both input and output is not supported"

      true ->
        opts
    end
  end

  defp elixir_endpoint?({type, _opts}) when type in [:reader, :writer, :stream, :message],
    do: true

  defp elixir_endpoint?(_io), do: false

  @spec start_server(opts_map(), :messages | :calls) :: boombox_server()
  defp start_server(opts, server_communication_medium) do
    {:ok, pid} =
      Boombox.Server.start(
        packet_serialization: false,
        stop_application: false,
        communication_medium: server_communication_medium,
        parent_pid: self()
      )

    Boombox.Server.run(pid, Map.to_list(opts))
    pid
  end

  @spec consume_stream(Enumerable.t(), pid(), procs()) :: term()
  defp consume_stream(stream, source, procs) do
    Enum.reduce_while(
      stream,
      %{demand: 0},
      fn
        %Boombox.Packet{} = packet, %{demand: 0} = state ->
          receive do
            {:boombox_demand, demand} ->
              send(source, packet)
              {:cont, %{state | demand: demand - 1}}

            {:DOWN, _monitor, :process, supervisor, _reason}
            when supervisor == procs.supervisor ->
              {:halt, :terminated}
          end

        %Boombox.Packet{} = packet, %{demand: demand} = state ->
          send(source, packet)
          {:cont, %{state | demand: demand - 1}}

        value, _state ->
          raise ArgumentError, "Expected Boombox.Packet.t(), got: #{inspect(value)}"
      end
    )
    |> case do
      :terminated ->
        :ok

      _state ->
        send(source, :boombox_eos)
        await_pipeline(procs)
    end
  end

  @spec produce_stream(pid(), procs()) :: Enumerable.t()
  defp produce_stream(sink, procs) do
    Stream.resource(
      fn ->
        %{sink: sink, procs: procs}
      end,
      fn %{sink: sink, procs: procs} = state ->
        send(sink, :boombox_demand)

        receive do
          %Boombox.Packet{} = packet ->
            verify_packet!(packet)
            {[packet], state}

          {:DOWN, _monitor, :process, supervisor, _reason}
          when supervisor == procs.supervisor ->
            {:halt, :eos}
        end
      end,
      fn
        %{procs: procs} -> terminate_pipeline(procs)
        :eos -> :ok
      end
    )
  end

  @spec start_pipeline(opts_map()) :: procs()
  defp start_pipeline(opts) do
    opts =
      opts
      |> Map.update!(:input, &resolve_stream_endpoint(&1, self()))
      |> Map.update!(:output, &resolve_stream_endpoint(&1, self()))
      |> Map.put(:parent, self())

    {:ok, supervisor, pipeline} =
      Membrane.Pipeline.start_link(Boombox.Pipeline, opts)

    Process.monitor(supervisor)
    %{supervisor: supervisor, pipeline: pipeline}
  end

  @spec terminate_pipeline(procs) :: :ok
  defp terminate_pipeline(procs) do
    Membrane.Pipeline.terminate(procs.pipeline)
    await_pipeline(procs)
  end

  @spec await_pipeline(procs) :: :ok
  defp await_pipeline(%{supervisor: supervisor}) do
    receive do
      {:DOWN, _monitor, :process, ^supervisor, _reason} -> :ok
    end
  end

  @spec await_source_ready() :: pid()
  defp await_source_ready() do
    receive do
      {:boombox_ex_stream_source, source} -> source
    end
  end

  @spec await_sink_ready() :: pid()
  defp await_sink_ready() do
    receive do
      {:boombox_ex_stream_sink, sink} -> sink
    end
  end

  # Waits for the external resource to be ready.
  # This is used to wait for the tcp/udp server to be ready before returning from async/2.
  # It is used for rtmp, rtmps, rtp, rtsp.
  @spec await_external_resource_ready() :: :ok
  defp await_external_resource_ready() do
    receive do
      :external_resource_ready ->
        :ok
    end
  end

  @spec verify_packet!(term()) :: :ok
  defp verify_packet!(packet) do
    %Boombox.Packet{kind: kind, pts: pts, format: format} = packet

    unless kind in [:audio, :video] do
      raise "Boombox.Packet field :kind must be set to :audio or :video, got #{inspect(kind)}"
    end

    unless Membrane.Time.is_time(pts) do
      raise "Boombox.Packet field :pts must be of type `Membrane.Time.t`, got #{inspect(pts)}"
    end

    unless is_map(format) do
      raise "Boombox.Packet field :format must be a map, got #{inspect(format)}"
    end

    :ok
  end

  defp resolve_stream_endpoint({:stream, stream_options}, parent),
    do: {:stream, parent, stream_options}

  defp resolve_stream_endpoint(endpoint, _parent), do: endpoint
end
