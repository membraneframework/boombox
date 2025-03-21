defmodule Boombox.Bin do
  @moduledoc false
  use Membrane.Bin

  require Membrane.Logger
  require Membrane.Transcoder.Audio
  require Membrane.Transcoder.Video
  alias Membrane.Transcoder

  @type track_builders :: %{
          optional(:audio) => Membrane.ChildrenSpec.t(),
          optional(:video) => Membrane.ChildrenSpec.t()
        }
  @type storage_type :: :file | :http

  defmodule Ready do
    @moduledoc false

    @type t :: %__MODULE__{
            actions: [Membrane.Pipeline.Action.t()],
            track_builders: Boombox.Bin.track_builders() | nil,
            spec_builder: Membrane.ChildrenSpec.t() | nil,
            eos_info: term
          }

    defstruct actions: [], track_builders: nil, spec_builder: [], eos_info: nil
  end

  defmodule Wait do
    @moduledoc false

    @type t :: %__MODULE__{actions: [Membrane.Pipeline.Action.t()]}
    defstruct actions: []
  end

  defmodule State do
    @moduledoc false

    @enforce_keys [:status, :input, :output, :parent]

    defstruct @enforce_keys ++
                [
                  actions_acc: [],
                  spec_builder: [],
                  track_builders: nil,
                  last_result: nil,
                  eos_info: nil,
                  rtsp_state: nil,
                  pending_new_tracks: %{input: [], output: []},
                  output_webrtc_state: nil
                ]

    @typedoc """
    Statuses of the Boombox pipeline in the order of occurence.

    Statuses starting with `awaiting_` occur only if
    the `proceed` function returns `t:Wait.t/0` when in the
    preceeding status.
    """
    @type status ::
            :init
            | :awaiting_output
            | :output_ready
            | :awaiting_input
            | :input_ready
            | :awaiting_output_link
            | :output_linked
            | :running

    @type t :: %__MODULE__{
            status: status(),
            input: Boombox.input(),
            output: Boombox.output(),
            actions_acc: [Membrane.Pipeline.Action.t()],
            spec_builder: Membrane.ChildrenSpec.t(),
            track_builders: Boombox.Bin.track_builders() | nil,
            last_result: Ready.t() | Wait.t() | nil,
            eos_info: term(),
            rtsp_state: Boombox.RTSP.state() | nil,
            parent: pid(),
            output_webrtc_state: Boombox.WebRTC.output_webrtc_state() | nil
          }
  end

  def_input_pad :audio_input,
    accepted_format: format when Transcoder.Audio.is_audio_format(format),
    availability: :on_request,
    max_instances: 1

  def_input_pad :video_input,
    accepted_format: format when Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 1

  def_options input: [default: :membrane_pad], output: [], parent: [default: nil]

  @impl true
  def handle_init(ctx, opts) do
    state = %State{
      input: opts.input,
      output: opts.output,
      parent: opts.parent,
      status: :init
    }

    with :membrane_pad <- state.input, {:stream, _opts} <- state.output do
      raise "Boombox bin cannot have pad input and stream output at the same time"
    end

    proceed(ctx, state)
  end

  @impl true
  def handle_playing(ctx, state) when state.input == :membrane_pad do
    cond do
      state.status in [:init, :awaiting_output] ->
        {[], state}

      # state.status in [:output_ready, :awaiting_input] ->
      state.status == :awaiting_input ->
        Boombox.Pad.create_input(ctx)
        |> proceed_result(ctx, state)

      true ->
        raise "internal boombox error (state.status is #{inspect(state.status)})"
    end
  end

  @impl true
  def handle_playing(_ctx, state), do: {[], state}

  @impl true
  def handle_pad_added(pad_ref, ctx, state) when state.input == :membrane_pad do
    actions = Boombox.Pad.handle_pad_added(pad_ref, ctx)
    {actions, state}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :mp4_demuxer, ctx, state) do
    Boombox.MP4.handle_input_tracks(tracks)
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_child_notification({:set_up_tracks, tracks}, :rtsp_source, ctx, state) do
    {result, state} = Boombox.RTSP.handle_set_up_tracks(tracks, state)
    proceed_result(result, ctx, state)
  end

  @impl true
  def handle_child_notification({:new_track, ssrc, track}, :rtsp_source, ctx, state) do
    {result, state} = Boombox.RTSP.handle_input_track(ssrc, track, state)
    proceed_result(result, ctx, state)
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :webrtc_input, ctx, state) do
    Boombox.WebRTC.handle_input_tracks(tracks)
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_child_notification({:negotiated_video_codecs, codecs}, :webrtc_output, ctx, state) do
    {result, state} = Boombox.WebRTC.handle_output_video_codecs_negotiated(codecs, state)
    proceed_result(result, ctx, state)
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :webrtc_output, ctx, state) do
    unless state.status == :awaiting_output_link do
      raise """
      Invalid status: #{inspect(state.status)}, expected :awaiting_output_link. \
      This is probably a bug in Boombox.
      """
    end

    {:webrtc, _signaling, webrtc_opts} = state.output

    Boombox.WebRTC.handle_output_tracks_negotiated(
      webrtc_opts,
      state.track_builders,
      state.spec_builder,
      tracks,
      state
    )
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_child_notification({:end_of_stream, id}, :webrtc_output, _ctx, state) do
    %{eos_info: track_ids} = state
    track_ids = List.delete(track_ids, id)
    state = %{state | eos_info: track_ids}

    if track_ids == [] do
      wait_before_closing()
      {[notify_parent: :processing_finished], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_child_notification(:end_of_stream, :hls_sink_bin, _ctx, state) do
    {[notify_parent: :processing_finished], state}
  end

  @impl true
  def handle_child_notification(notification, child, _ctx, state) do
    Membrane.Logger.debug_verbose(
      "Ignoring notification #{inspect(notification)} from child #{inspect(child)}"
    )

    {[], state}
  end

  @impl true
  def handle_info({:rtmp_client_ref, client_ref}, ctx, state) do
    Boombox.RTMP.handle_connection(client_ref)
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_element_end_of_stream(:mp4_file_sink, :input, _ctx, state) do
    {[notify_parent: :processing_finished], state}
  end

  @impl true
  def handle_element_end_of_stream(:udp_rtp_sink, :input, _ctx, state) do
    {[notify_parent: :processing_finished], state}
  end

  @impl true
  def handle_element_end_of_stream(:elixir_stream_sink, Pad.ref(:input, id), _ctx, state) do
    eos_info = List.delete(state.eos_info, id)
    state = %{state | eos_info: eos_info}

    case eos_info do
      [] -> {[notify_parent: :processing_finished], state}
      _eos_info -> {[], state}
    end
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end

  @spec proceed_result(Ready.t() | Wait.t(), Membrane.Bin.CallbackContext.t(), State.t()) ::
          Membrane.Pipeline.callback_return()
  defp proceed_result(result, ctx, %{status: :awaiting_output} = state) do
    do_proceed(result, :output_ready, :awaiting_output, ctx, state)
  end

  defp proceed_result(result, ctx, %{status: :awaiting_input} = state) do
    do_proceed(result, :input_ready, :awaiting_input, ctx, state)
  end

  defp proceed_result(result, ctx, %{status: :awaiting_output_link} = state) do
    do_proceed(result, :output_linked, :awaiting_output_link, ctx, state)
  end

  defp proceed_result(result, ctx, %{status: :running} = state) do
    do_proceed(result, :running, :running, ctx, state)
  end

  defp proceed_result(_result, _ctx, state) do
    raise """
    Boombox got into invalid internal state. Status: #{inspect(state.status)}.
    """
  end

  @spec proceed(Membrane.Bin.CallbackContext.t(), State.t()) ::
          Membrane.Pipeline.callback_return()
  defp proceed(ctx, %{status: :init} = state) do
    {ready_or_wait, state} = create_output(state.output, ctx, state)
    do_proceed(ready_or_wait, :output_ready, :awaiting_output, ctx, state)
  end

  defp proceed(ctx, %{status: :output_ready} = state) do
    create_input(state.input, ctx, state)
    |> do_proceed(:input_ready, :awaiting_input, ctx, state)
  end

  defp proceed(
         ctx,
         %{
           status: :input_ready,
           last_result: %Ready{track_builders: track_builders, spec_builder: spec_builder}
         } = state
       )
       when track_builders != nil do
    state = %{state | track_builders: track_builders, spec_builder: spec_builder}

    link_output(state.output, track_builders, spec_builder, ctx, state)
    |> do_proceed(:output_linked, :awaiting_output_link, ctx, state)
  end

  defp proceed(ctx, %{status: :output_linked} = state) do
    do_proceed(%Wait{}, nil, :running, ctx, %{state | eos_info: state.last_result.eos_info})
  end

  defp proceed(_ctx, state) do
    raise """
    Boombox got into invalid internal state. Status: #{inspect(state.status)}.
    """
  end

  @spec do_proceed(
          Ready.t() | Wait.t(),
          State.status() | nil,
          State.status() | nil,
          Membrane.Bin.CallbackContext.t(),
          State.t()
        ) :: Membrane.Pipeline.callback_return()
  defp do_proceed(result, ready_status, wait_status, ctx, state) do
    %{actions_acc: actions_acc} = state

    case result do
      %Ready{actions: actions} = result when ready_status != nil ->
        proceed(ctx, %{
          state
          | status: ready_status,
            last_result: result,
            actions_acc: actions_acc ++ actions
        })

      %Wait{actions: actions} when wait_status != nil ->
        {actions_acc ++ actions, %{state | actions_acc: [], status: wait_status}}
    end
  end

  @spec create_input(Boombox.input(), Membrane.Bin.CallbackContext.t(), State.t()) ::
          Ready.t() | Wait.t()
  defp create_input({:webrtc, signaling}, ctx, state) do
    Boombox.WebRTC.create_input(signaling, state.output, ctx, state)
  end

  defp create_input({:mp4, location, opts}, _ctx, _state) do
    Boombox.MP4.create_input(location, opts)
  end

  defp create_input({:rtmp, src}, ctx, _state) do
    Boombox.RTMP.create_input(src, ctx.utility_supervisor)
  end

  defp create_input({:rtsp, uri}, _ctx, _state) do
    Boombox.RTSP.create_input(uri)
  end

  defp create_input({:rtp, opts}, _ctx, _state) do
    Boombox.RTP.create_input(opts)
  end

  defp create_input({:stream, params}, _ctx, state) do
    Boombox.ElixirStream.create_input(state.parent, params)
  end

  defp create_input(:membrane_pad, ctx, _state) do
    Boombox.Pad.create_input(ctx)
  end

  @spec create_output(Boombox.output(), Membrane.Bin.CallbackContext.t(), State.t()) ::
          {Ready.t() | Wait.t(), State.t()}
  defp create_output({:webrtc, signaling, _opts}, ctx, state) do
    Boombox.WebRTC.create_output(signaling, ctx, state)
  end

  defp create_output(_output, _ctx, state) do
    {%Ready{}, state}
  end

  @spec link_output(
          Boombox.output(),
          track_builders(),
          Membrane.ChildrenSpec.t(),
          Membrane.Bin.CallbackContext.t(),
          State.t()
        ) ::
          Ready.t() | Wait.t()
  defp link_output({:webrtc, _signaling, opts}, track_builders, spec_builder, _ctx, state) do
    tracks = [
      %{kind: :audio, id: :audio_track},
      %{kind: :video, id: :video_tracks}
    ]

    Boombox.WebRTC.link_output(opts, track_builders, spec_builder, tracks, state)
  end

  defp link_output({:mp4, location, opts}, track_builders, spec_builder, _ctx, _state) do
    Boombox.MP4.link_output(location, opts, track_builders, spec_builder)
  end

  defp link_output({:hls, location, opts}, track_builders, spec_builder, _ctx, _state) do
    Boombox.HLS.link_output(location, opts, track_builders, spec_builder)
  end

  defp link_output({:rtp, opts}, track_builders, spec_builder, _ctx, _state) do
    Boombox.RTP.link_output(opts, track_builders, spec_builder)
  end

  defp link_output({:stream, opts}, track_builders, spec_builder, _ctx, state) do
    Boombox.ElixirStream.link_output(state.parent, opts, track_builders, spec_builder)
  end

  # Wait between sending the last packet
  # and terminating boombox, to avoid closing
  # any connection before the other peer
  # receives the last packet.
  defp wait_before_closing() do
    Process.sleep(500)
  end
end
