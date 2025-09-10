defmodule Boombox.InternalBin.SRT do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad

  alias Boombox.InternalBin.{Ready, Wait}
  alias Membrane.{AAC, H264, SRT, Transcoder}

  @type state :: %{
          server: pid(),
          stream_id: String.t()
        }

  @spec create_input(String.t() | pid()) :: Wait.t()
  def create_input(server_awaiting_accept) when is_pid(server_awaiting_accept) do
    handle_connection(server_awaiting_accept)
  end

  def create_input(url) do
    {ip, port, stream_id, password} = parse_srt_url(url)

    spec = [
      child(:srt_source, %SRT.Source{ip: ip, port: port, stream_id: stream_id, password: password})
      |> child(:srt_mpeg_ts_demuxer, Membrane.MPEG.TS.Demuxer)
    ]

    %Wait{actions: [spec: spec]}
  end

  @spec handle_connection(pid()) :: Wait.t()
  def handle_connection(server_awaiting_accept) do
    spec = [
      child(:srt_source, %SRT.Source{server_awaiting_accept: server_awaiting_accept})
      |> child(:srt_mpeg_ts_demuxer, Membrane.MPEG.TS.Demuxer)
    ]

    %Wait{actions: [spec: spec]}
  end

  @spec handle_child_notification(term()) :: Ready.t()
  def handle_child_notification({:mpeg_ts_pmt, pmt}) do
    track_builders =
      Enum.map(pmt.streams, fn {id, %{stream_type: type}} ->
        get_child(:srt_mpeg_ts_demuxer)
        |> via_out(Pad.ref(:output, {:stream_id, id}))
        |> then(
          &case type do
            :H264 ->
              {:video, child(&1, %H264.Parser{output_stream_structure: :avc1})}

            :AAC ->
              {:audio, child(&1, %AAC.Parser{out_encapsulation: :none, output_config: :esds})}
          end
        )
      end)
      |> Map.new()

    %Ready{track_builders: track_builders}
  end

  @spec link_output(
          String.t(),
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(url, track_builders, spec_builder) do
    {ip, port, stream_id, password} = parse_srt_url(url)

    spec =
      [
        spec_builder,
        child(:srt_mpeg_ts_muxer, Membrane.MPEGTS.Muxer)
        |> child(:srt_realtimer, Membrane.Realtimer)
        |> child(:srt_sink, %SRT.Sink{
          ip: ip,
          port: port,
          stream_id: stream_id,
          password: password
        }),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:srt_mpeg_ts_audio_transcoder, %Transcoder{
              output_stream_format: AAC
            })
            |> via_in(:audio_input)
            |> get_child(:srt_mpeg_ts_muxer)

          {:video, builder} ->
            builder
            |> child(:srt_mpeg_ts_video_transcoder, %Transcoder{
              output_stream_format: %H264{stream_structure: :annexb}
            })
            |> via_in(:video_input)
            |> get_child(:srt_mpeg_ts_muxer)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end

  defp parse_srt_url(url) do
    parsed_url = URI.parse(url)
    ip = parsed_url.host
    port = parsed_url.port

    params_string =
      case parsed_url.query do
        nil -> ""
        path -> path
      end

    params =
      String.split(params_string, "&")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn key_value_pair ->
        [key, value] = String.split(key_value_pair, "=")
        {key, value}
      end)
      |> Enum.into(%{})

    {ip, port, params["streamid"] || "", params["password"] || ""}
  end
end
