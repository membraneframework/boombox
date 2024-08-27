defmodule Membrane.Support.RTSP.Server.Pipeline do
  @moduledoc false

  use Membrane.Pipeline

  @spec start_link(map()) :: Membrane.Pipeline.on_start()
  def start_link(config) do
    Membrane.Pipeline.start_link(__MODULE__, config)
  end

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      child(:mp4_in_file_source, %Membrane.File.Source{
        location: opts.fixture_path,
        seekable?: true
      })
      |> child(:mp4_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})

    {[spec: spec], opts}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :mp4_demuxer, _ctx, state) do
    spec =
      Enum.map(tracks, fn
        {id, %Membrane.AAC{}} ->
          get_child(:mp4_demuxer)
          |> via_out(Pad.ref(:output, id))
          |> child(Membrane.Debug.Sink)

        {id, %Membrane.H264{}} ->
          get_child(:mp4_demuxer)
          |> via_out(Pad.ref(:output, id))
          |> child(:parser, %Membrane.H264.Parser{
            output_alignment: :nalu,
            repeat_parameter_sets: true,
            skip_until_keyframe: true,
            output_stream_structure: :annexb
          })
          |> via_in(Pad.ref(:input, state.ssrc),
            options: [payloader: Membrane.RTP.H264.Payloader]
          )
          |> child(:rtp, Membrane.RTP.SessionBin)
          |> via_out(Pad.ref(:rtp_output, state.ssrc),
            options: [
              payload_type: state.pt,
              clock_rate: state.clock_rate
            ]
          )
          |> child(:udp_sink, %Membrane.UDP.Sink{
            destination_address: state.client_ip,
            destination_port_no: state.client_port,
            local_socket: state.server_rtp_socket
          })
      end)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(:udp_sink, :input, _ctx, state) do
    Process.sleep(50)
    :gen_tcp.close(state.socket)
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state) do
    {[], state}
  end
end
