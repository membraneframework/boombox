defmodule Boombox.Pipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(ctx, opts) do
    state = %{
      status: :init,
      input: opts[:input],
      output: opts[:output],
      spec: [],
      rtmp_tcp_server: nil,
      end_of_streams: []
    }

    try_proceed(ctx, state)
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :mp4_demuxer, ctx, state) do
    [{audio_id, %Membrane.AAC{}}, {video_id, %Membrane.H264{}}] =
      Enum.sort_by(tracks, fn {_id, %format{}} -> format end)

    spec =
      get_child(:mp4_demuxer)
      |> via_out(Pad.ref(:output, audio_id))
      |> child(Membrane.AAC.Parser)
      |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)

    builders = %{
      audio: get_child(:aac_decoder),
      video: get_child(:mp4_demuxer) |> via_out(Pad.ref(:output, video_id))
    }

    proceed({:ready, spec, builders}, ctx, state)
  end

  @impl true
  def handle_child_notification(
        {:socket_control_needed, _socket, source_pid},
        :rtmp_source,
        _ctx,
        state
      ) do
    send(state.rtmp_tcp_server, {:rtmp_source_pid, source_pid})
    {[], state}
  end

  @impl true
  def handle_child_notification({:end_of_stream, _id}, :webrtc_output, _ctx, state) do
    if :webrtc_output in state.end_of_streams do
      Process.sleep(500)
      {[terminate: :normal], state}
    else
      {[], %{state | end_of_streams: [:webrtc_output | state.end_of_streams]}}
    end
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_info({:rtmp_tcp_server, _server_pid, _socket}, _ctx, state)
      when state.rtmp_tcp_server do
    send(state.rtmp_tcp_server, :rtmp_already_connected)
    {[], state}
  end

  @impl true
  def handle_info({:rtmp_tcp_server, server_pid, socket}, ctx, state) do
    spec = [
      child(:rtmp_source, %Membrane.RTMP.SourceBin{socket: socket})
      |> via_out(:audio)
      |> child(Membrane.AAC.Parser)
      |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)
    ]

    builders = %{
      audio: get_child(:aac_decoder),
      video: get_child(:rtmp_source) |> via_out(:video)
    }

    proceed({:ready, spec, builders}, ctx, %{state | rtmp_tcp_server: server_pid})
  end

  @impl true
  def handle_element_end_of_stream(:mp4_file_sink, :input, _ctx, state) do
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end

  defp proceed(result, ctx, %{status: :awaiting_input} = state) do
    case result do
      {:ready, spec, builders} -> continue({:input_ready, builders}, spec, ctx, state)
      {:wait, spec} -> wait(:awaiting_input, spec, state)
    end
  end

  defp try_proceed(ctx, %{status: :init, input: input} = state) do
    case create_input(input, ctx) do
      {:ready, spec, builders} -> continue({:input_ready, builders}, spec, ctx, state)
      {:wait, spec} -> wait(:awaiting_input, spec, state)
    end
  end

  defp try_proceed(ctx, %{status: {:input_ready, builders}, output: output} = state) do
    case create_output(output, builders, ctx) do
      {:ready, spec} -> continue(:output_ready, spec, ctx, state)
      {:wait, spec} -> wait(:awaiting_output, spec, state)
    end
  end

  defp try_proceed(_ctx, %{status: :output_ready} = state) do
    wait(:running, [], state)
  end

  defp continue(status, spec, ctx, %{spec: spec_acc} = state) do
    try_proceed(ctx, %{state | status: status, spec: spec_acc ++ [spec]})
  end

  defp wait(status, spec, %{spec: spec_acc} = state) do
    {[spec: spec_acc ++ [spec]], %{state | spec: [], status: status}}
  end

  defp create_input([:webrtc, signaling], _ctx) do
    signaling =
      case signaling do
        %Membrane.WebRTC.SignalingChannel{} = signaling ->
          signaling

        uri when is_binary(uri) ->
          uri = URI.new!(uri)
          {:ok, ip} = :inet.getaddr(~c"#{uri.host}", :inet)
          {:websocket, ip: ip, port: uri.port}
      end

    spec = [
      child(:webrtc_input, %Membrane.WebRTC.Source{
        signaling: signaling,
        video_codec: :h264
      }),
      get_child(:webrtc_input)
      |> via_out(:output, options: [kind: :audio])
      |> child(:opus_decoder, Membrane.Opus.Decoder)
    ]

    builders = %{
      audio: get_child(:opus_decoder),
      video:
        get_child(:webrtc_input)
        |> via_out(:output, options: [kind: :video])
    }

    {:ready, spec, builders}
  end

  defp create_input([:file, :mp4, name], _ctx) do
    spec =
      child(%Membrane.File.Source{location: name, seekable?: true})
      |> child(:mp4_demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})

    {:wait, spec}
  end

  defp create_input([:rtmp, uri], ctx) do
    uri = URI.new!(uri)
    {:ok, ip} = :inet.getaddr(~c"#{uri.host}", :inet)

    boombox = self()

    server_options = %Membrane.RTMP.Source.TcpServer{
      port: uri.port,
      listen_options: [:binary, packet: :raw, active: false, ip: ip],
      socket_handler: fn socket ->
        send(boombox, {:rtmp_tcp_server, self(), socket})

        receive do
          {:rtmp_source_pid, pid} -> {:ok, pid}
          :rtmp_already_connected -> {:error, :rtmp_already_connected}
        end
      end
    }

    {:ok, _pid} =
      Membrane.UtilitySupervisor.start_link_child(
        ctx.utility_supervisor,
        {Membrane.RTMP.Source.TcpServer, server_options}
      )

    {:wait, []}
  end

  defp create_output([:webrtc, signaling], builders, _ctx) do
    signaling =
      case signaling do
        %Membrane.WebRTC.SignalingChannel{} = signaling ->
          signaling

        uri when is_binary(uri) ->
          uri = URI.new!(uri)
          {:ok, ip} = :inet.getaddr(~c"#{uri.host}", :inet)
          {:websocket, ip: ip, port: uri.port}
      end

    spec = [
      child(:webrtc_output, %Membrane.WebRTC.Sink{
        signaling: signaling,
        video_codec: :h264
      }),
      builders.video
      |> child(Membrane.Realtimer)
      |> child(%Membrane.H264.Parser{output_stream_structure: :annexb, output_alignment: :nalu})
      |> via_in(Pad.ref(:input, :video_track), options: [kind: :video])
      |> get_child(:webrtc_output),
      builders.audio
      |> child(%Membrane.FFmpeg.SWResample.Converter{
        output_stream_format: %Membrane.RawAudio{
          sample_format: :s16le,
          sample_rate: 48_000,
          channels: 2
        }
      })
      |> child(Membrane.Opus.Encoder)
      |> child(Membrane.Realtimer)
      |> via_in(Pad.ref(:input, :audio_track), options: [kind: :audio])
      |> get_child(:webrtc_output)
    ]

    {:ready, spec}
  end

  defp create_output([:file, :mp4, name], builders, _ctx) do
    spec =
      [
        child(:mp4_muxer, Membrane.MP4.Muxer.ISOM)
        |> child(:mp4_file_sink, %Membrane.File.Sink{location: name}),
        builders.audio
        |> child(Membrane.AAC.FDK.Encoder)
        |> child(%Membrane.AAC.Parser{out_encapsulation: :none, output_config: :esds})
        |> get_child(:mp4_muxer),
        builders.video
        |> child(%Membrane.H264.Parser{output_stream_structure: :avc3})
        |> get_child(:mp4_muxer)
      ]

    {:ready, spec}
  end
end
