defmodule Boombox.RTP do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Membrane.RTP
  alias Membrane.RTP.PayloadFormat
  alias Boombox.Pipeline.{Ready, State, Wait}

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

  @spec create_input(Boombox.in_rtp_opts()) :: Wait.t()
  def create_input(opts) do
    _parsed_options = validate_and_parse_options(opts)

    spec =
      child(:udp_source, %Membrane.UDP.Source{local_port_no: opts[:port]})
      |> child(:rtp_demuxer, Membrane.RTP.Demuxer)

    %Wait{actions: [spec: spec]}
  end

  @spec handle_new_rtp_stream(
          ExRTP.Packet.uint32(),
          ExRTP.Packet.uint7(),
          [ExRTP.Packet.Extension.t()],
          State.t()
        ) :: {Wait.t() | Ready.t(), State.t()}
  def handle_new_rtp_stream(ssrc, payload_type, _extensions, state) do
    {:rtp, rtp_opts} = state.input

    parsed_opts = validate_and_parse_options(rtp_opts)

    {media_type, track_config} =
      Enum.find(parsed_opts.track_configs, fn {_media_type, track_config} ->
        track_config.payload_type == payload_type
      end)

    %PayloadFormat{depayloader: depayloader} = PayloadFormat.get(track_config.encoding_name)

    spec =
      case track_config.encoding_name do
        :H264 ->
          ppss = Map.get(track_config.encoding_specific_params, :ppss, [])
          spss = Map.get(track_config.encoding_specific_params, :spss, [])

          get_child(:rtp_demuxer)
          |> via_out(Membrane.Pad.ref(:output, ssrc))
          |> child({:jitter_buffer, ssrc}, %Membrane.RTP.JitterBuffer{
            clock_rate: track_config.clock_rate
          })
          |> child({:rtp_depayloader, ssrc}, depayloader)
          |> child({:rtp_in_parser, ssrc}, %Membrane.H264.Parser{ppss: ppss, spss: spss})

        :AAC ->
          audio_specific_config = track_config.encoding_specific_params.audio_specific_config
          bitrate_mode = track_config.encoding_specific_params.bitrate_mode

          get_child(:rtp_demuxer)
          |> via_out(Membrane.Pad.ref(:output, ssrc))
          |> child({:jitter_buffer, ssrc}, %Membrane.RTP.JitterBuffer{
            clock_rate: track_config.clock_rate
          })
          |> child({:rtp_depayloader, ssrc}, struct(depayloader, mode: bitrate_mode))
          |> child({:rtp_in_parser, ssrc}, %Membrane.AAC.Parser{
            audio_specific_config: audio_specific_config
          })
          |> child(:rtp_in_aac_decoder, Membrane.AAC.FDK.Decoder)
      end

    state =
      if state.track_builders == nil do
        %{state | track_builders: %{media_type => spec}}
      else
        Bunch.Struct.put_in(state, [:track_builders, media_type], spec)
      end

    if Enum.all?(rtp_opts[:track_configs], fn {media_type, _track_config} ->
         Map.has_key?(state.track_builders, media_type)
       end) do
      {%Ready{actions: [], track_builders: state.track_builders}, state}
    else
      {%Wait{actions: []}, state}
    end
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

    {_payload_format, payload_type, clock_rate} = RTP.PayloadFormat.resolve(track_config)

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
