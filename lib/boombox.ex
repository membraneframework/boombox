defmodule Boombox do
  @moduledoc """
  Boombox is a tool for audio and video streaming.

  See `run/1` for details and [examples.livemd](examples.livemd) for examples.
  """

  require Logger
  require Membrane.Time
  require Membrane.Transcoder.{Audio, Video}

  alias Membrane.RTP

  @type transcoding_policy() :: {:transcoding_policy, :always | :if_needed | :never}

  @type webrtc_signaling :: Membrane.WebRTC.Signaling.t() | String.t()
  @type in_stream_opts :: [
          {:audio, :binary | boolean()}
          | {:video, :image | boolean()}
        ]
  @type out_stream_opts :: [
          {:audio, :binary | boolean()}
          | {:video, :image | boolean()}
          | {:audio_format, Membrane.RawAudio.SampleFormat.t()}
          | {:audio_rate, Membrane.RawAudio.sample_rate_t()}
          | {:audio_channels, Membrane.RawAudio.channels_t()}
          | {:video_width, non_neg_integer()}
          | {:video_height, non_neg_integer()}
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
          | transcoding_policy()
        ]

  @type input ::
          (path_or_uri :: String.t())
          | {:mp4, location :: String.t(), transport: :file | :http}
          | {:h264, location :: String.t(),
             transport: :file | :http, framerate: Membrane.H264.framerate()}
          | {:h265, location :: String.t(),
             transport: :file | :http, framerate: Membrane.H265.framerate_t()}
          | {:aac, location :: String.t(), transport: :file | :http}
          | {:wav, location :: String.t(), transport: :file | :http}
          | {:mp3, location :: String.t(), transport: :file | :http}
          | {:ivf, location :: String.t(), transport: :file | :http}
          | {:ogg, location :: String.t(), transport: :file | :http}
          | {:webrtc, webrtc_signaling()}
          | {:whip, uri :: String.t(), token: String.t()}
          | {:rtmp, (uri :: String.t()) | (client_handler :: pid)}
          | {:rtsp, url :: String.t()}
          | {:rtp, in_rtp_opts()}
          | {:stream, in_stream_opts()}

  @type output ::
          (path_or_uri :: String.t())
          | {path_or_uri :: String.t(), [transcoding_policy()]}
          | {:mp4, location :: String.t()}
          | {:h264, location :: String.t()}
          | {:h265, location :: String.t()}
          | {:aac, location :: String.t()}
          | {:wav, location :: String.t()}
          | {:mp3, location :: String.t()}
          | {:ivf, location :: String.t()}
          | {:ogg, location :: String.t()}
          | {:mp4, location :: String.t(), [transcoding_policy()]}
          | {:webrtc, webrtc_signaling()}
          | {:webrtc, webrtc_signaling(), [transcoding_policy()]}
          | {:whip, uri :: String.t(), [{:token, String.t()} | {bandit_option :: atom(), term()}]}
          | {:hls, location :: String.t()}
          | {:hls, location :: String.t(), [transcoding_policy()]}
          | {:rtp, out_rtp_opts()}
          | {:stream, out_stream_opts()}

  @typep procs :: %{pipeline: pid(), supervisor: pid()}
  @typep opts_map :: %{
           input: input(),
           output: output()
         }

  @doc """
  Runs boombox with given input and output.

  ## Example

  ```
  Boombox.run(input: "rtmp://localhost:5432", output: "index.m3u8")
  ```

  See `t:input/0` and `t:output/0` for available outputs and [examples.livemd](examples.livemd)
  for examples.

  If the input is `{:stream, opts}`, a `Stream` or other `Enumerable` is expected
  as the first argument.
  ```
  Boombox.run(
    input: "path/to/file.mp4",
    output: {:webrtc, "ws://0.0.0.0:1234"}
  )
  ```
  """
  @spec run(Enumerable.t() | nil,
          input: input(),
          output: output()
        ) :: :ok | Enumerable.t()
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

      opts ->
        opts
        |> start_pipeline()
        |> await_pipeline()
    end
  end

  @doc """
  Asynchronous version of run/2
  Doesn't block the calling process until the termination of the pipeline.
  It returns a `Task` that can be awaited later.
  If the output is a stream the behaviour is identical to run/2
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

      # In case of rtsp, rtmp, rtp, rtmps, we need to wait for the tcp/udp server to be ready
      # before returning from async/2.
      %{input: {protocol, _opts}} when protocol in [:rtmp, :rtp, :rtsp, :rtmps] ->
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

  @endpoint_opts [:input, :output]
  defp validate_opts!(stream, opts) do
    opts = opts |> Keyword.validate!(@endpoint_opts) |> Map.new()

    cond do
      Map.keys(opts) -- @endpoint_opts != [] ->
        raise ArgumentError, "Both input and output are required"

      is_stream?(opts[:input]) && !Enumerable.impl_for(stream) ->
        raise ArgumentError,
              "Expected Enumerable.t() to be passed as the first argument, got #{inspect(stream)}"

      is_stream?(opts[:input]) && is_stream?(opts[:output]) ->
        raise ArgumentError,
              ":stream on both input and output is not supported"

      true ->
        opts
    end
  end

  defp is_stream?({:stream, _opts}), do: true
  defp is_stream?(_), do: false

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
