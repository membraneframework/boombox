defmodule Boombox.RTP do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Membrane.RTP.PayloadFormat
  alias Membrane.RTP
  alias Boombox.Pipeline.Ready

  @required_opts [:port, :track_configs]
  @required_encoding_specific_params %{
    AAC: [bitrate_mode: [require?: true], audio_specific_config: [require?: true]],
    H264: [ppss: [require?: false], spss: [require?: false]]
  }

  @type parsed_encoding_specific_params ::
          %{bitrate_mode: RTP.AAC.Utils.mode(), audio_specific_config: binary()}
          | %{optional(:ppss) => [binary()], optional(:spss) => [binary()]}
          | %{}

  @type parsed_track_config :: %{
          encoding_name: RTP.encoding_name(),
          encoding_specific_params: parsed_encoding_specific_params(),
          payload_type: RTP.payload_type(),
          clock_rate: RTP.clock_rate()
        }

  @type parsed_in_opts :: %{
          port: :inet.port_number(),
          track_configs: %{audio: parsed_track_config(), video: parsed_track_config()}
        }

  @spec create_input(Boombox.in_rtp_opts()) :: Ready.t()
  def create_input(opts) do
    parsed_options = validate_and_parse_options(opts)

    spec =
      child(:udp_source, %Membrane.UDP.Source{local_port_no: opts[:port]})
      |> child(:rtp_demuxer, Membrane.RTP.Demuxer)

    track_builders =
      Map.new(parsed_options.track_configs, fn {media_type, track_config} ->
        %PayloadFormat{depayloader: depayloader} = PayloadFormat.get(track_config.encoding_name)

        case track_config.encoding_name do
          :H264 ->
            ppss = Map.get(track_config.encoding_specific_params, :ppss, [])
            spss = Map.get(track_config.encoding_specific_params, :spss, [])

            spec =
              get_child(:rtp_demuxer)
              |> via_out(:output, options: [stream_id: {:encoding_name, :H264}])
              |> child(:h264_jitter_buffer, %Membrane.RTP.JitterBuffer{
                clock_rate: track_config.clock_rate
              })
              |> child(:rtp_h264_depayloader, depayloader)
              |> child(:rtp_in_h264_parser, %Membrane.H264.Parser{ppss: ppss, spss: spss})

            {media_type, spec}

          :AAC ->
            audio_specific_config = track_config.encoding_specific_params.audio_specific_config
            bitrate_mode = track_config.encoding_specific_params.bitrate_mode

            spec =
              get_child(:rtp_demuxer)
              |> via_out(:output, options: [stream_id: {:encoding_name, :AAC}])
              |> child(:aac_jitter_buffer, %Membrane.RTP.JitterBuffer{
                clock_rate: track_config.clock_rate
              })
              |> child(:rtp_aac_depayloader, struct(depayloader, mode: bitrate_mode))
              |> child(:rtp_in_aac_parser, %Membrane.AAC.Parser{
                audio_specific_config: audio_specific_config
              })

            {media_type, spec}
        end
      end)

    %Ready{spec_builder: spec, track_builders: track_builders}
  end

  @spec validate_and_parse_options(Boombox.in_rtp_opts()) :: parsed_in_opts()
  defp validate_and_parse_options(opts) do
    Enum.each(@required_opts, fn required_option ->
      unless Keyword.has_key?(opts, required_option) do
        raise "Required option #{inspect(required_option)} not present in passed RTP options"
      end
    end)

    if opts[:track_configs] == [] do
      raise "No media configured"
    end

    parsed_track_configs =
      Map.new(opts[:track_configs], fn {media_type, track_config} ->
        {media_type, validate_and_parse_track_config!(track_config)}
      end)

    %{port: opts[:port], track_configs: parsed_track_configs}
  end

  @spec validate_and_parse_track_config!(Boombox.rtp_track_config()) :: parsed_track_config()
  defp validate_and_parse_track_config!(track_config) do
    {encoding_name, encoding_specific_params} =
      validate_and_parse_encoding!(track_config[:encoding])

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

  @spec validate_and_parse_encoding!(RTP.encoding_name() | Boombox.rtp_encoding_specific_params()) ::
          {RTP.encoding_name(), %{}} | parsed_encoding_specific_params()
  defp validate_and_parse_encoding!(encoding) do
    case encoding do
      nil ->
        raise "Encoding name not provided"

      encoding when is_atom(encoding) ->
        validate_and_parse_encoding!({encoding, []})

      {encoding, encoding_params} when is_atom(encoding) ->
        field_specs = Map.get(@required_encoding_specific_params, encoding)

        if field_specs != nil do
          {:ok, encoding_params} = Bunch.Config.parse(encoding_params, field_specs)
          {encoding, encoding_params}
        else
          {encoding, []}
        end
    end
  end
end
