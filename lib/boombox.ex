defmodule Boombox do
  @moduledoc """
  Boombox is a tool for audio and video streaming.

  See `run/1` for details and [examples.livemd](examples.livemd) for examples.
  """
  require Membrane.Time

  alias Membrane.RTP

  @type webrtc_signaling :: Membrane.WebRTC.SignalingChannel.t() | String.t()
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
        ]

  @typedoc """
  Some encodings can/must be accompanied with encoding specific parameters:
    * AAC:
      - bitrate_mode - MUST be provided for both RTP input and output. Defines which mode should be assumed/set when depayloading/payloading.
      - audio_specific_config - MUST be provided for RTP input. Contains crucial information about the stream and has to be obtained from a side channel.
    * H264 and H265:
      - vpss (H265 only), ppss, spss - MAY be provided for RTP input. picture and sequence parameter sets, could be obtained from a side channel. They contain information about the encoded stream.
  """
  @type rtp_encoding_specific_params ::
          {:AAC, [{:bitrate_mode, RTP.AAC.Utils.mode()} | {:audio_specific_config, binary()}]}
          | {:H264, [{:ppss, [binary()]} | {:spss, [binary()]}]}
          | {:H265, [{:vpss, [binary()]} | {:ppss, [binary()]} | {:spss, [binary()]}]}

  @typedoc """
  For each media type the following parameters are specified:
    * encoding - MUST be provided for both RTP input and output, some encodings require additional parameters, see `rtp_encoding_specific_params/0`.
    * payload_type, clock rate - MAY be provided for both RTP input and output, if not, then an unofficial default will be used.
  """
  @type rtp_track_config :: [
          {:encoding, RTP.encoding_name() | rtp_encoding_specific_params()}
          | {:payload_type, RTP.payload_type()}
          | {:clock_rate, RTP.clock_rate()}
        ]

  @typedoc """
  In order to configure RTP input both a receiving port and media configurations must be provided.
  At least one media type needs to be configured.
  """
  @type in_rtp_opts :: [
          {:port, :inet.port_number()}
          | {:track_configs,
             [
               {:audio, rtp_track_config()}
               | {:video, rtp_track_config()}
             ]}
        ]

  @typedoc """
  In order to configure RTP output the destination and media configurations must be provided.
  At least one media type needs to be configured.
  """
  @type out_rtp_opts :: [
          {:address, :inet.ip_address()}
          | {:port, :inet.port_number()}
          | {:track_configs,
             [
               {:audio, rtp_track_config()}
               | {:video, rtp_track_config()}
             ]}
        ]

  @type input ::
          (path_or_uri :: String.t())
          | {:mp4, location :: String.t(), transport: :file | :http}
          | {:webrtc, webrtc_signaling()}
          | {:rtmp, (uri :: String.t()) | (client_handler :: pid)}
          | {:rtsp, url :: String.t()}
          | {:rtp, in_rtp_opts()}
          | {:stream, in_stream_opts()}

  @type output ::
          (path_or_uri :: String.t())
          | {:mp4, location :: String.t()}
          | {:webrtc, webrtc_signaling()}
          | {:hls, location :: String.t()}
          | {:rtp, out_rtp_opts()}
          | {:stream, out_stream_opts()}

  @typep procs :: %{pipeline: pid(), supervisor: pid()}
  @typep opts_map :: %{input: input(), output: output()}

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
  """
  @spec run(Enumerable.t() | nil, input: input(), output: output()) :: :ok | Enumerable.t()
  def run(stream \\ nil, opts) do
    opts_keys = [:input, :output]
    opts = Keyword.validate!(opts, opts_keys) |> Map.new(fn {k, v} -> {k, parse_opt!(k, v)} end)

    if key = Enum.find(opts_keys, fn k -> not is_map_key(opts, k) end) do
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

  @spec parse_opt!(:input, input()) :: input()
  @spec parse_opt!(:output, output()) :: output()
  defp parse_opt!(direction, value) when is_binary(value) do
    uri = URI.parse(value)
    scheme = uri.scheme
    extension = if uri.path, do: Path.extname(uri.path)

    case {scheme, extension, direction} do
      {scheme, ".mp4", :input} when scheme in [nil, "http", "https"] -> {:mp4, value}
      {nil, ".mp4", :output} -> {:mp4, value}
      {scheme, _ext, :input} when scheme in ["rtmp", "rtmps"] -> {:rtmp, value}
      {"rtsp", _ext, :input} -> {:rtsp, value}
      {nil, ".m3u8", :output} -> {:hls, value}
      _other -> raise ArgumentError, "Unsupported URI: #{value} for direction: #{direction}"
    end
    |> then(&parse_opt!(direction, &1))
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_opt!(direction, value) when is_tuple(value) do
    case value do
      {:mp4, location} when is_binary(location) and direction == :input ->
        parse_opt!(:input, {:mp4, location, []})

      {:mp4, location, opts} when is_binary(location) and direction == :input ->
        if Keyword.keyword?(opts),
          do: {:mp4, location, transport: resolve_transport(location, opts)}

      {:mp4, location} when is_binary(location) and direction == :output ->
        {:mp4, location}

      {:webrtc, %Membrane.WebRTC.SignalingChannel{}} ->
        value

      {:webrtc, uri} when is_binary(uri) ->
        value

      {:rtmp, arg} when direction == :input and (is_binary(arg) or is_pid(arg)) ->
        value

      {:hls, location} when direction == :output and is_binary(location) ->
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
    case Keyword.validate!(opts, transport: nil)[:transport] do
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
end
