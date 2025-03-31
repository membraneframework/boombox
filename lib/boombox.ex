defmodule Boombox do
  @moduledoc """
  Boombox is a tool for audio and video streaming.

  See `run/1` for details and [examples.livemd](examples.livemd) for examples.
  """
  require Logger
  require Membrane.Time
  require Boombox.StorageEndpoints, as: StorageEndpoints

  alias Membrane.RTP

  @type force_transcoding() :: {:force_transcoding, boolean() | :audio | :video}

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
          | force_transcoding()
        ]

  @type input ::
          (path_or_uri :: String.t())
          | {:mp4, location :: String.t(), transport: :file | :http}
          | {:h264, location :: String.t(),
             transport: :file | :http, framerate: Membrane.H264.framerate()}
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
          | {path_or_uri :: String.t(), [force_transcoding()]}
          | {:mp4, location :: String.t()}
          | {:h264, location :: String.t()}
          | {:aac, location :: String.t()}
          | {:wav, location :: String.t()}
          | {:mp3, location :: String.t()}
          | {:ivf, location :: String.t()}
          | {:ogg, location :: String.t()}
          | {:mp4, location :: String.t(), [force_transcoding()]}
          | {:webrtc, webrtc_signaling()}
          | {:webrtc, webrtc_signaling(), [force_transcoding()]}
          | {:whip, uri :: String.t(), [{:token, String.t()} | {bandit_option :: atom(), term()}]}
          | {:hls, location :: String.t()}
          | {:hls, location :: String.t(), [force_transcoding()]}
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
  @endpoint_opts [:input, :output]
  def run(stream \\ nil, opts) do
    opts =
      opts
      |> Keyword.validate!(@endpoint_opts)
      |> Map.new(fn {key, value} -> {key, parse_endpoint_opt!(key, value)} end)

    :ok = maybe_log_transcoding_related_warning(opts)

    if key = Enum.find(@endpoint_opts, fn k -> not is_map_key(opts, k) end) do
      raise "#{key} is not provided"
    end

    case opts do
      %{input: {:stream, _in_stream_opts}, output: {:stream, _out_stream_opts}} ->
        raise ArgumentError, ":stream on both input and output is not supported"

      %{input: {:stream, _stream_opts}} ->
        unless Enumerable.impl_for(stream) do
          raise ArgumentError,
                "Expected Enumerable.t() to be passed as the first argument, got #{inspect(stream)}"
        end

        consume_stream(stream, opts)

      %{output: {:stream, _stream_opts}} ->
        produce_stream(opts)

      opts ->
        opts
        |> start_pipeline()
        |> await_pipeline()
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

  @spec parse_endpoint_opt!(:input, input()) :: input()
  @spec parse_endpoint_opt!(:output, output()) :: output()
  defp parse_endpoint_opt!(direction, value) when is_binary(value) do
    parse_endpoint_opt!(direction, {value, []})
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_endpoint_opt!(direction, {value, opts}) when is_binary(value) do
    uri = URI.parse(value)
    scheme = uri.scheme
    extension = if uri.path, do: Path.extname(uri.path)

    case {scheme, extension, direction} do
      {scheme, extension, :input}
      when scheme in [nil, "http", "https"] and
             StorageEndpoints.is_storage_endpoint_extension(extension) ->
        {StorageEndpoints.get_storage_endpoint_type!(extension), value, opts}

      {nil, extension, :output} when StorageEndpoints.is_storage_endpoint_extension(extension) ->
        {StorageEndpoints.get_storage_endpoint_type!(extension), value, opts}

      {scheme, _ext, :input} when scheme in ["rtmp", "rtmps"] ->
        {:rtmp, value}

      {"rtsp", _ext, :input} ->
        {:rtsp, value}

      {nil, ".m3u8", :output} ->
        {:hls, value, opts}

      _other ->
        raise ArgumentError, "Unsupported URI: #{value} for direction: #{direction}"
    end
    |> then(&parse_endpoint_opt!(direction, &1))
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_endpoint_opt!(direction, value) when is_tuple(value) do
    case value do
      {endpoint_type, location}
      when is_binary(location) and direction == :input and
             StorageEndpoints.is_storage_endpoint_type(endpoint_type) ->
        parse_endpoint_opt!(:input, {endpoint_type, location, []})

      {:h264, location, opts} when is_binary(location) and direction == :input ->
        {:h264, location,
         transport: resolve_transport(location, opts), framerate: opts[:framerate] || {30, 1}}

      {endpoint_type, location, opts}
      when is_binary(location) and direction == :input and
             StorageEndpoints.is_storage_endpoint_type(endpoint_type) ->
        {endpoint_type, location, transport: resolve_transport(location, opts)}

      {:mp4, location} when is_binary(location) and direction == :output ->
        {:mp4, location, []}

      {:mp4, location, _opts} when is_binary(location) and direction == :output ->
        value

      {endpoint_type, location}
      when is_binary(location) and direction == :output and
             StorageEndpoints.is_storage_endpoint_type(endpoint_type) ->
        value

      {:webrtc, %Membrane.WebRTC.Signaling{}} when direction == :input ->
        value

      {:webrtc, %Membrane.WebRTC.Signaling{} = signaling} ->
        {:webrtc, signaling, []}

      {:webrtc, %Membrane.WebRTC.Signaling{}, _opts} when direction == :output ->
        value

      {:webrtc, uri} when is_binary(uri) and direction == :input ->
        value

      {:webrtc, uri} when is_binary(uri) and direction == :output ->
        {:webrtc, uri, []}

      {:webrtc, uri, _opts} when is_binary(uri) and direction == :output ->
        value

      {:whip, uri} when is_binary(uri) ->
        parse_endpoint_opt!(direction, {:whip, uri, []})

      {:whip, uri, opts} when is_binary(uri) and is_list(opts) and direction == :input ->
        if Keyword.keyword?(opts), do: {:webrtc, value}

      {:whip, uri, opts} when is_binary(uri) and is_list(opts) and direction == :output ->
        {webrtc_opts, whip_opts} = split_webrtc_and_whip_opts(opts)
        if Keyword.keyword?(opts), do: {:webrtc, {:whip, uri, whip_opts}, webrtc_opts}

      {:rtmp, arg} when direction == :input and (is_binary(arg) or is_pid(arg)) ->
        value

      {:hls, location} when direction == :output and is_binary(location) ->
        {:hls, location, []}

      {:hls, location, opts}
      when direction == :output and is_binary(location) and is_list(opts) ->
        value

      {:rtsp, location} when direction == :input and is_binary(location) ->
        value

      {:rtp, opts} ->
        if Keyword.keyword?(opts), do: value

      {:stream, opts} ->
        if Keyword.keyword?(opts), do: value

      _other ->
        nil
    end
    |> case do
      nil -> raise ArgumentError, "Invalid #{direction} specification: #{inspect(value)}"
      value -> value
    end
  end

  defguardp is_webrtc_endpoint(endpoint)
            when is_tuple(endpoint) and elem(endpoint, 0) in [:webrtc, :whip]

  @spec maybe_log_transcoding_related_warning(opts_map()) :: :ok
  def maybe_log_transcoding_related_warning(opts) do
    if is_webrtc_endpoint(opts.output) and not is_webrtc_endpoint(opts.input) and
         webrtc_output_force_transcoding(opts) not in [true, :video] do
      Logger.warning("""
      Boombox output protocol is WebRTC, while Boombox input doesn't support keyframe requests. This \
      might lead to issues with the output video if the output stream isn't sent only by localhost. You \
      can solve this by setting `:force_transcoding` output option to `true` or `:video`, but be aware \
      that it will increase Boombox CPU usage.
      """)
    end

    :ok
  end

  defp webrtc_output_force_transcoding(%{output: {:webrtc, _singaling, opts}}),
    do: Keyword.get(opts, :force_transcoding)

  @spec consume_stream(Enumerable.t(), opts_map()) :: term()
  defp consume_stream(stream, opts) do
    procs = start_pipeline(opts)

    source =
      receive do
        {:boombox_ex_stream_source, source} -> source
      end

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

  @spec produce_stream(opts_map()) :: Enumerable.t()
  defp produce_stream(opts) do
    Stream.resource(
      fn ->
        procs = start_pipeline(opts)

        receive do
          {:boombox_ex_stream_sink, sink} -> %{sink: sink, procs: procs}
        end
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
    {:ok, supervisor, pipeline} =
      Membrane.Pipeline.start_link(Boombox.Pipeline, Map.put(opts, :parent, self()))

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

  @spec resolve_transport(String.t(), [{:transport, :file | :http}]) :: :file | :http
  defp resolve_transport(location, opts) do
    case Keyword.validate!(opts, transport: nil, force_transcoding: false)[:transport] do
      nil ->
        uri = URI.parse(location)

        case uri.scheme do
          nil -> :file
          "http" -> :http
          "https" -> :http
          _other -> raise ArgumentError, "Unsupported URI: #{location}"
        end

      transport when transport in [:file, :http] ->
        transport

      transport ->
        raise ArgumentError, "Invalid transport: #{inspect(transport)}"
    end
  end

  defp split_webrtc_and_whip_opts(opts) do
    opts
    |> Enum.split_with(fn {key, _value} -> key == :force_transcoding end)
  end
end
