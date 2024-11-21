defmodule Boombox.RTP do
  @moduledoc false
  alias Membrane.RTP.PayloadFormat
  alias Boombox.Pipeline.{Ready, State, Wait}

  import Membrane.ChildrenSpec

  require Membrane.Pad

  @required_opts [:port, :media_types]

  @spec create_input(Boombox.in_rtp_opts()) :: Wait.t()
  def create_input(opts) do
    validate_options!(opts)

    if Keyword.has_key?(opts, :fmt_mapping) do
      Enum.each(opts.fmt_mapping, fn {payload_type, {encoding_name, clock_rate}} ->
        PayloadFormat.register_payload_type_mapping(
          payload_type,
          encoding_name,
          clock_rate
        )
      end)
    end

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
    payload_type |> IO.inspect(label: "aaaa")

    %{encoding_name: encoding_name, clock_rate: clock_rate} =
      PayloadFormat.get_payload_type_mapping(payload_type)

    {:rtp, rtp_opts} = state.input
    %PayloadFormat{depayloader: depayloader} = PayloadFormat.get(encoding_name)

    {spec, media_type} =
      case encoding_name do
        :H264 ->
          ppss = get_in(rtp_opts, [:encoding_specific_params, :H264, :ppss]) || []
          spss = get_in(rtp_opts, [:encoding_specific_params, :H264, :spss]) || []

          spec =
            get_child(:rtp_demuxer)
            |> via_out(Membrane.Pad.ref(:output, ssrc))
            |> child({:jitter_buffer, ssrc}, %Membrane.RTP.JitterBuffer{clock_rate: clock_rate})
            |> child({:rtp_depayloader, ssrc}, depayloader)
            |> child({:rtp_in_parser, ssrc}, %Membrane.H264.Parser{ppss: ppss, spss: spss})

          {spec, :video}

        :AAC ->
          audio_specific_config =
            get_in(rtp_opts, [:encoding_specific_params, :AAC, :audio_specific_config])

          bitrate_mode = get_in(rtp_opts, [:encoding_specific_params, :AAC, :bitrate_mode])

          if bitrate_mode == nil do
            raise "AAC stream received, but bitrate_mode, that's needed for depayloading the stream, was not provided"
          end

          spec =
            get_child(:rtp_demuxer)
            |> via_out(Membrane.Pad.ref(:output, ssrc))
            |> child({:jitter_buffer, ssrc}, %Membrane.RTP.JitterBuffer{clock_rate: clock_rate})
            |> child({:rtp_depayloader, ssrc}, struct(depayloader, mode: bitrate_mode))
            |> child({:rtp_in_parser, ssrc}, %Membrane.AAC.Parser{
              audio_specific_config: audio_specific_config
            })
            |> child(:rtp_in_aac_decoder, Membrane.AAC.FDK.Decoder)

          {spec, :audio}
      end

    state =
      if state.track_builders == nil do
        %{state | track_builders: %{media_type => spec}}
      else
        Bunch.Struct.put_in(state, [:track_builders, media_type], spec)
      end

    if Enum.all?(rtp_opts[:media_types], fn media_type ->
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
  end
end
