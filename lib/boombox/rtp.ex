defmodule Boombox.RTP do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Membrane.RTP
  alias Membrane.RTP.PayloadFormat
  alias Boombox.Pipeline.{Ready, State, Wait}

  @required_opts [:port, :media_config]
  @required_encoding_specific_params %{
    AAC: [bitrate_mode: [require?: true], audio_specific_config: [require?: true]],
    H264: [ppss: [require?: false], spss: [require?: false]]
  }

  @type parsed_encoding_specific_params ::
          {:AAC, %{bitrate_mode: RTP.AAC.Utils.mode(), audio_specific_config: binary()}}
          | {:H264, %{optional(:ppss) => [binary()], optional(:spss) => [binary()]}}

  @type parsed_media_config :: %{
          encoding: parsed_encoding_specific_params(),
          payload_type: RTP.payload_type_t(),
          clock_rate: RTP.clock_rate_t()
        }

  @type parsed_in_opts :: %{
          port: :inet.port_number(),
          media_config: %{audio: parsed_media_config(), video: parsed_media_config()}
        }

  @spec create_input(Boombox.in_rtp_opts()) :: Wait.t()
  def create_input(opts) do
    validate_options!(opts)

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

    {media_type, media_config} =
      Enum.find(rtp_opts, fn {_media_type, media_config} ->
        media_config[:payload_type] == payload_type
      end)

    {encoding_name, encoding_specific_params} =
      case media_config[:encoding] do
        encoding_name when is_atom(encoding_name) -> {encoding_name, []}
        encoding_params -> encoding_params
      end

    %PayloadFormat{depayloader: depayloader} = PayloadFormat.get(encoding_name)

    spec =
      case encoding_name do
        :H264 ->
          ppss = Keyword.get(encoding_specific_params, :ppss, [])
          spss = Keyword.get(encoding_specific_params, :spss, [])

          get_child(:rtp_demuxer)
          |> via_out(Membrane.Pad.ref(:output, ssrc))
          |> child({:jitter_buffer, ssrc}, %Membrane.RTP.JitterBuffer{
            clock_rate: media_config[:clock_rate]
          })
          |> child({:rtp_depayloader, ssrc}, depayloader)
          |> child({:rtp_in_parser, ssrc}, %Membrane.H264.Parser{ppss: ppss, spss: spss})

        :AAC ->
          audio_specific_config = encoding_specific_params[:audio_specific_config]
          bitrate_mode = encoding_specific_params[:bitrate_mode]

          get_child(:rtp_demuxer)
          |> via_out(Membrane.Pad.ref(:output, ssrc))
          |> child({:jitter_buffer, ssrc}, %Membrane.RTP.JitterBuffer{
            clock_rate: media_config[:clock_rate]
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

    if Enum.all?(rtp_opts[:media_config], fn {media_type, _media_config} ->
         Map.has_key?(state.track_builders, media_type)
       end) do
      {%Ready{actions: [], track_builders: state.track_builders}, state}
    else
      {%Wait{actions: []}, state}
    end
  end

  @spec validate_options!(Boombox.in_rtp_opts()) :: :ok
  defp validate_options!(opts) do
    Enum.each(@required_opts, fn required_option ->
      unless Keyword.has_key?(opts, required_option) do
        raise "Required option #{inspect(required_option)} not present in passed RTP options"
      end
    end)

    if opts[:media_config] == [] do
      raise "No media configured"
    end

    Enum.each(opts[:media_config], fn {_media_type, media_config} ->
      validate_media_config!(media_config)
    end)
  end

  @spec validate_media_config!(Boombox.rtp_media_config()) :: :ok
  defp validate_media_config!(media_config) do
    encoding = validate_encoding!(media_config[:encoding])

    payload_format = PayloadFormat.get(encoding)

    {clock_rate, payload_type} =
      case payload_format.payload_type do
        nil ->
          {nil, nil}

        payload_type ->
          case PayloadFormat.get_payload_type_mapping(payload_type) do
            %{encoding_name: ^encoding, clock_rate: clock_rate} ->
              {clock_rate, payload_type}

            %{} ->
              {nil, payload_type}
          end
      end

    {:ok, parsed_media_config} =
      Bunch.Config.parse(media_config,
        encoding: [],
        payload_type: fn _cfg -> if payload_type != nil, do: [default: payload_type], else: [] end,
        clock_rate: fn _cfg -> if clock_rate != nil, do: [default: clock_rate], else: [] end
      )

    if clock_rate == nil do
      PayloadFormat.register_payload_type_mapping(
        parsed_media_config.payload_type,
        encoding,
        parsed_media_config.clock_rate
      )
    end

    :ok
  end

  @spec validate_encoding!(RTP.encoding_name_t() | Boombox.rtp_encoding_specific_params()) ::
          RTP.encoding_name_t()
  defp validate_encoding!(encoding) do
    case encoding do
      nil ->
        raise "Encoding name not provided"

      {encoding, encoding_params} when is_atom(encoding) ->
        field_specs = Map.get(@required_encoding_specific_params, encoding)
        {:ok, _encoding_params} = Bunch.Config.parse(encoding_params, field_specs)
        encoding

      encoding when is_atom(encoding) ->
        validate_encoding!({encoding, []})
    end
  end
end
