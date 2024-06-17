defmodule Boombox.Pipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(ctx, opts) do
    state = %{
      status: :init,
      input: opts[:input],
      output: opts[:output],
      spec: [],
      rtmp_input_state: nil,
      end_of_streams: []
    }

    proceed(ctx, state)
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :mp4_demuxer, ctx, state) do
    Boombox.MP4.handle_input_tracks(tracks)
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_child_notification(
        {:socket_control_needed, _socket, source_pid},
        :rtmp_source,
        ctx,
        state
      ) do
    Boombox.RTMP.handle_socket_control(source_pid, state.rtmp_input_state)
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_child_notification({:end_of_stream, _id}, :webrtc_output, _ctx, state) do
    if :webrtc_output in state.end_of_streams do
      wait_before_closing()
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
  def handle_info({:rtmp_tcp_server, server_pid, socket}, ctx, state) do
    {result, rtmp_input_state} =
      Boombox.RTMP.handle_connection(server_pid, socket, state.rtmp_input_state)

    proceed_result(result, ctx, %{state | rtmp_input_state: rtmp_input_state})
  end

  @impl true
  def handle_element_end_of_stream(:mp4_file_sink, :input, _ctx, state) do
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end

  defp proceed_result(result, ctx, %{status: :awaiting_input} = state) do
    do_proceed(result, :input_ready, :awaiting_input, ctx, state)
  end

  defp proceed_result(result, ctx, %{status: :running} = state) do
    do_proceed(result, nil, :running, ctx, state)
  end

  defp proceed(ctx, %{status: :init, input: input} = state) do
    create_input(input, ctx)
    |> do_proceed(:input_ready, :awaiting_input, ctx, state)
  end

  defp proceed(ctx, %{status: {:input_ready, builders}, output: output} = state) do
    create_output(output, builders, ctx)
    |> do_proceed(:output_ready, :awaiting_output, ctx, state)
  end

  defp proceed(ctx, %{status: :output_ready} = state) do
    do_proceed({:wait, []}, nil, :running, ctx, state)
  end

  defp do_proceed(result, ready_status, wait_status, ctx, state) do
    %{spec: spec_acc} = state

    case result do
      {:ready, spec} when ready_status != nil ->
        proceed(ctx, %{state | status: ready_status, spec: spec_acc ++ [spec]})

      {:ready, spec, value} when ready_status != nil ->
        proceed(ctx, %{state | status: {ready_status, value}, spec: spec_acc ++ [spec]})

      {:wait, spec} when wait_status != nil ->
        {[spec: spec_acc ++ [spec]], %{state | spec: [], status: wait_status}}
    end
  end

  defp create_input([:webrtc, signaling], _ctx) do
    Boombox.WebRTC.create_input(signaling)
  end

  defp create_input([:file, :mp4, location], _ctx) do
    Boombox.MP4.create_input(location)
  end

  defp create_input([:rtmp, uri], ctx) do
    Boombox.RTMP.create_input(uri, ctx.utility_supervisor)
  end

  defp create_output([:webrtc, signaling], builders, _ctx) do
    Boombox.WebRTC.create_output(signaling, builders)
  end

  defp create_output([:file, :mp4, location], builders, _ctx) do
    Boombox.MP4.create_output(location, builders)
  end

  # Wait between sending the last packet
  # and terminating boombox, to avoid closing
  # any connection before the other peer
  # receives the last packet.
  defp wait_before_closing() do
    Process.sleep(500)
  end
end
