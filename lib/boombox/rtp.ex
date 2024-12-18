defmodule Boombox.RTP do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Boombox.Pipeline.Ready
  alias Membrane.RTP

  @required_opts %{
    input: [:port, :track_configs],
    output: [:address, :port, :track_configs]
  }

  @required_encoding_specific_params %{
    input: %{
      AAC: [bitrate_mode: [require?: true], audio_specific_config: [require?: true]],
      H264: [ppss: [require?: false], spss: [require?: false]],
      H265: [vpss: [require?: false], ppss: [require?: false], spss: [require?: false]]
    },
    output: %{
      AAC: [bitrate_mode: [require?: true]]
    }
  }

  @type parsed_input_encoding_specific_params ::
          %{bitrate_mode: RTP.AAC.Utils.mode(), audio_specific_config: binary()}
          | %{optional(:ppss) => [binary()], optional(:spss) => [binary()]}
          | %{
              optional(:vpss) => [binary()],
              optional(:ppss) => [binary()],
              optional(:spss) => [binary()]
            }
          | %{}

  @type parsed_output_encoding_specific_params ::
          %{bitrate_mode: RTP.AAC.Utils.mode()}
          | %{}

  @type parsed_input_track_config :: %{
          encoding_name: RTP.encoding_name(),
          encoding_specific_params: parsed_input_encoding_specific_params(),
          payload_type: RTP.payload_type(),
          clock_rate: RTP.clock_rate()
        }

  @type parsed_output_track_config :: %{
          encoding_name: RTP.encoding_name(),
          encoding_specific_params: parsed_output_encoding_specific_params(),
          payload_type: RTP.payload_type(),
          clock_rate: RTP.clock_rate()
        }

  @type parsed_in_opts :: %{
          port: :inet.port_number(),
          track_configs: %{
            optional(:audio) => parsed_input_track_config(),
            optional(:video) => parsed_input_track_config()
          }
        }

  @type parsed_out_opts :: %{
          address: :inet.ip_address(),
          port: :inet.port_number(),
          track_configs: %{
            optional(:audio) => parsed_output_track_config(),
            optional(:video) => parsed_output_track_config()
          }
        }

  @type parsed_track_config :: parsed_input_track_config() | parsed_output_track_config()

  @spec create_input(Boombox.in_rtp_opts()) :: Ready.t()
  def create_input(opts) do
    parsed_options = validate_and_parse_options(:input, opts)
    payload_type_mapping = get_payload_type_mapping(parsed_options.track_configs)

    spec =
      child(:udp_source, %Membrane.UDP.Source{local_port_no: opts[:port]})
      |> child(:rtp_demuxer, %Membrane.RTP.Demuxer{payload_type_mapping: payload_type_mapping})

    track_builders =
      Map.new(parsed_options.track_configs, fn {media_type, track_config} ->
        {depayloader, parser} =
          case track_config.encoding_name do
            :H264 ->
              ppss = Map.get(track_config.encoding_specific_params, :ppss, [])
              spss = Map.get(track_config.encoding_specific_params, :spss, [])
              {Membrane.RTP.H264.Depayloader, %Membrane.H264.Parser{ppss: ppss, spss: spss}}

            :AAC ->
              audio_specific_config = track_config.encoding_specific_params.audio_specific_config
              bitrate_mode = track_config.encoding_specific_params.bitrate_mode

              {%Membrane.RTP.AAC.Depayloader{mode: bitrate_mode},
               %Membrane.AAC.Parser{audio_specific_config: audio_specific_config}}

            :OPUS ->
              {Membrane.RTP.Opus.Depayloader, Membrane.Opus.Parser}

            :H265 ->
              vpss = Map.get(track_config.encoding_specific_params, :vpss, [])
              ppss = Map.get(track_config.encoding_specific_params, :ppss, [])
              spss = Map.get(track_config.encoding_specific_params, :spss, [])

              {Membrane.RTP.H265.Depayloader,
               %Membrane.H265.Parser{vpss: vpss, ppss: ppss, spss: spss}}
          end

        spec =
          get_child(:rtp_demuxer)
          |> via_out(:output, options: [stream_id: {:encoding_name, track_config.encoding_name}])
          |> child({:jitter_buffer, media_type}, %Membrane.RTP.JitterBuffer{
            clock_rate: track_config.clock_rate
          })
          |> child({:rtp_depayloader, media_type}, depayloader)
          |> child({:rtp_in_parser, media_type}, parser)

        {media_type, spec}
      end)

    %Ready{spec_builder: spec, track_builders: track_builders}
  end

  @spec link_output(
          Boombox.out_rtp_opts(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(opts, track_builders, spec_builder) do
    parsed_opts = validate_and_parse_options(:output, opts)

    spec = [
      spec_builder,
      child(:rtp_muxer, Membrane.RTP.Muxer)
      |> child(:udp_sink, %Membrane.UDP.Sink{
        destination_address: parsed_opts.address,
        destination_port_no: parsed_opts.port
      }),
      Enum.map(track_builders, fn {media_type, builder} ->
        track_config = parsed_opts.track_configs[media_type]

        {output_stream_format, parser, payloader} =
          case track_config.encoding_name do
            :H264 ->
              {%Membrane.H264{stream_structure: :annexb, alignment: :nalu},
               %Membrane.H264.Parser{output_stream_structure: :annexb, output_alignment: :nalu},
               Membrane.RTP.H264.Payloader}

            :AAC ->
              {%Membrane.AAC{encapsulation: :none},
               %Membrane.AAC.Parser{out_encapsulation: :none},
               %Membrane.RTP.AAC.Payloader{
                 mode: track_config.encoding_specific_params.bitrate_mode,
                 frames_per_packet: 1
               }}
          end

        builder
        |> child({:rtp_transcoder, media_type}, %Boombox.Transcoder{
          output_stream_format: output_stream_format
        })
        |> child({:rtp_out_parser, media_type}, parser)
        |> child({:rtp_payloader, media_type}, payloader)
        |> child({:realtimer, media_type}, Membrane.Realtimer)
        |> via_in(:input,
          options: [
            encoding: track_config.encoding_name,
            payload_type: track_config.payload_type,
            clock_rate: track_config.clock_rate
          ]
        )
        |> get_child(:rtp_muxer)

        # builder
        # |> child(:rtp_audio_transcoder, %Boombox.Transcoder{
        # output_stream_format: %Membrane.AAC{encapsulation: :none}
        # })
        # |> child(:aac_payloader, %Membrane.RTP.AAC.Payloader{
        # mode: track_config.encoding_specific_params.bitrate_mode,
        # frames_per_packet: 1
        # })
        # |> via_in(:input,
        # options: [
        # encoding: :AAC,
        # payload_type: track_config.payload_type,
        # clock_rate: track_config.clock_rate
        # ]
        # )
        # |> get_child(:rtp_muxer)

        # {:video, builder} ->
        # track_config = parsed_opts.track_configs.video

        # builder
        # |> get_child(:rtp_muxer)
        # |> child(:hls_video_transcoder, %Boombox.Transcoder{
        # output_stream_format: %Membrane.H264{
        # stream_structure: :annexb,
        # alignment: :nalu
        # }
        # })
        # |> child(:h264_payloader, Membrane.RTP.H264.Payloader)
        # |> via_in(:input,
        # options: [
        # encoding: :H264,
        # payload_type: track_config.payload_type,
        # clock_rate: track_config.clock_rate
        # ]
        # )
        # |> get_child(:rtp_muxer)
      end)
    ]

    %Ready{actions: [spec: spec]}
  end

  @spec validate_and_parse_options(:input, Boombox.in_rtp_opts()) :: parsed_in_opts()
  @spec validate_and_parse_options(:output, Boombox.out_rtp_opts()) :: parsed_out_opts()
  defp validate_and_parse_options(direction, opts) do
    Enum.each(@required_opts[direction], fn required_option ->
      unless Keyword.has_key?(opts, required_option) do
        raise "Required option #{inspect(required_option)} not present in passed RTP options"
      end
    end)

    if opts[:track_configs] == [] do
      raise "No RTP media configured"
    end

    parsed_track_configs =
      Map.new(opts[:track_configs], fn {media_type, track_config} ->
        {media_type, validate_and_parse_track_config!(direction, track_config)}
      end)

    case direction do
      :input ->
        %{port: opts[:port], track_configs: parsed_track_configs}

      :output ->
        %{address: opts[:address], port: opts[:port], track_configs: parsed_track_configs}
    end
  end

  @spec validate_and_parse_track_config!(:input, Boombox.rtp_track_config()) ::
          parsed_input_track_config()
  @spec validate_and_parse_track_config!(:output, Boombox.rtp_track_config()) ::
          parsed_output_track_config()
  defp validate_and_parse_track_config!(direction, track_config) do
    {encoding_name, encoding_specific_params} =
      validate_and_parse_encoding!(direction, track_config[:encoding])

    track_config = Keyword.put(track_config, :encoding_name, encoding_name)

    %{payload_type: payload_type, clock_rate: clock_rate} =
      RTP.PayloadFormat.resolve(track_config)

    if payload_type == nil do
      raise "payload_type for encoding #{inspect(encoding_name)} not provided with no default value registered"
    end

    if clock_rate == nil do
      raise "clock_rate for encoding #{inspect(encoding_name)} and payload_type #{inspect(payload_type)} not provided with no default value registered"
    end

    %{
      encoding_name: encoding_name,
      encoding_specific_params: encoding_specific_params,
      payload_type: payload_type,
      clock_rate: clock_rate
    }
  end

  @spec validate_and_parse_encoding!(
          :input,
          RTP.encoding_name() | Boombox.rtp_encoding_specific_params()
        ) :: {RTP.encoding_name(), parsed_input_encoding_specific_params()}
  @spec validate_and_parse_encoding!(
          :output,
          RTP.encoding_name() | Boombox.rtp_encoding_specific_params()
        ) :: {RTP.encoding_name(), parsed_output_encoding_specific_params()}
  defp validate_and_parse_encoding!(direction, encoding) do
    case encoding do
      nil ->
        raise "Encoding name not provided"

      encoding when is_atom(encoding) ->
        validate_and_parse_encoding!(direction, {encoding, []})

      {encoding, encoding_params} when is_atom(encoding) ->
        field_specs = Map.get(@required_encoding_specific_params[direction], encoding, [])
        {:ok, encoding_params} = Bunch.Config.parse(encoding_params, field_specs)
        {encoding, encoding_params}
    end
  end

  @spec get_payload_type_mapping(%{audio: parsed_track_config(), video: parsed_track_config()}) ::
          RTP.PayloadFormat.payload_type_mapping()
  defp get_payload_type_mapping(track_configs) do
    Map.new(track_configs, fn {_media_type, track_config} ->
      {track_config.payload_type,
       %{encoding_name: track_config.encoding_name, clock_rate: track_config.clock_rate}}
    end)
  end
end
