defmodule Boombox.Pipeline do
  @moduledoc false
  # The pipeline that spawns all the Boombox children.
  # Support for each endpoint is handled via create_output, create_input
  # and link_output functions. Each of them should return one of:
  # - `t:Ready.t/0` - Returns the control to Boombox.
  # - `t:Wait.t/0 - Waits for some endpoint-specific action to happen.
  #   When it does, `proceed_result` needs to be called with `Ready`
  #   or another `Wait`.
  #
  # The purpose of each function is the following:
  # - create_output - Called at the beginning, initializes the output.
  #   Needed only when the output needs initialization before tracks
  #   are known.
  # - create_input - Initializes the input. Called after the output finishes
  #   initialization. Should return `t:track_builders/0` in `Ready`.
  #   If there's any spec that needs to be returned with the track builders,
  #   it can be set in the `spec_builder` field of `Ready`.
  # - link_output - Gets the track builders and spec builder. It should
  #   link the track builders to appropriate inputs and return the spec
  #   builder in the same spec.

  use Membrane.Pipeline

  @type track_builders :: %{
          optional(:audio) => Membrane.ChildrenSpec.t(),
          optional(:video) => Membrane.ChildrenSpec.t()
        }

  defmodule Ready do
    @moduledoc false

    @type t :: %__MODULE__{
            actions: [Membrane.Pipeline.Action.t()],
            track_builders: Boombox.Pipeline.track_builders() | nil,
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

    @enforce_keys [:status, :input, :output]

    defstruct @enforce_keys ++
                [
                  actions_acc: [],
                  spec_builder: [],
                  track_builders: nil,
                  last_result: nil,
                  eos_info: nil,
                  rtmp_input_state: nil
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
            track_builders: Boombox.Pipeline.track_builders() | nil,
            last_result: Boombox.Pipeline.Ready.t() | Boombox.Pipeline.Wait.t() | nil,
            eos_info: term,
            rtmp_input_state: Boombox.RTMP.state()
          }
  end

  @impl true
  def handle_init(ctx, opts) do
    state = %State{
      input: opts |> Keyword.fetch!(:input) |> parse_input(),
      output: opts |> Keyword.fetch!(:output) |> parse_output(),
      status: :init
    }

    proceed(ctx, state)
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :mp4_demuxer, ctx, state) do
    Boombox.MP4.handle_input_tracks(tracks)
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :webrtc_input, ctx, state) do
    Boombox.WebRTC.handle_input_tracks(tracks)
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
  def handle_child_notification({:new_tracks, tracks}, :webrtc_output, ctx, state) do
    %{status: :awaiting_output_link} = state

    Boombox.WebRTC.handle_output_tracks_negotiated(
      state.track_builders,
      state.spec_builder,
      tracks
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
      {[terminate: :normal], state}
    else
      {[], state}
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

  @spec proceed_result(Ready.t() | Wait.t(), Membrane.Pipeline.CallbackContext.t(), State.t()) ::
          Membrane.Pipeline.callback_return()
  defp proceed_result(result, ctx, %{status: :awaiting_input} = state) do
    do_proceed(result, :input_ready, :awaiting_input, ctx, state)
  end

  defp proceed_result(result, ctx, %{status: :awaiting_output_link} = state) do
    do_proceed(result, :output_linked, :awaiting_output_link, ctx, state)
  end

  defp proceed_result(result, ctx, %{status: :running} = state) do
    do_proceed(result, nil, :running, ctx, state)
  end

  defp proceed_result(_result, _ctx, state) do
    raise """
    Boombox got into invalid internal state. Status: #{inspect(state.status)}.
    """
  end

  @spec proceed(Membrane.Pipeline.CallbackContext.t(), State.t()) ::
          Membrane.Pipeline.callback_return()
  defp proceed(ctx, %{status: :init} = state) do
    create_output(state.output, ctx)
    |> do_proceed(:output_ready, :awaiting_output, ctx, state)
  end

  defp proceed(ctx, %{status: :output_ready} = state) do
    create_input(state.input, ctx)
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

    link_output(state.output, track_builders, spec_builder, ctx)
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
          Membrane.Pipeline.CallbackContext.t(),
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

  @spec create_input(Boombox.input(), Membrane.Pipeline.CallbackContext.t()) ::
          Ready.t() | Wait.t()
  defp create_input([:webrtc, signaling], _ctx) do
    Boombox.WebRTC.create_input(signaling)
  end

  defp create_input([:file, :mp4, location], _ctx) do
    Boombox.MP4.create_input(location)
  end

  defp create_input([:rtmp, uri], ctx) do
    Boombox.RTMP.create_input(uri, ctx.utility_supervisor)
  end

  @spec create_output(Boombox.output(), Membrane.Pipeline.CallbackContext.t()) ::
          Ready.t() | Wait.t()
  defp create_output([:webrtc, signaling], _ctx) do
    Boombox.WebRTC.create_output(signaling)
  end

  defp create_output(_output, _ctx) do
    %Ready{}
  end

  @spec link_output(
          Boombox.output(),
          track_builders(),
          Membrane.ChildrenSpec.t(),
          Membrane.Pipeline.CallbackContext.t()
        ) ::
          Ready.t() | Wait.t()
  defp link_output([:webrtc, _signaling], track_builders, _spec_builder, _ctx) do
    Boombox.WebRTC.link_output(track_builders)
  end

  defp link_output([:file, :mp4, location], track_builders, spec_builder, _ctx) do
    Boombox.MP4.link_output(location, track_builders, spec_builder)
  end

  defp parse_input(input) when is_binary(input) do
    uri = URI.new!(input)

    cond do
      uri.scheme == nil and Path.extname(uri.path) == ".mp4" ->
        [:file, :mp4, uri.path]

      uri.scheme == "rtmp" ->
        [:rtmp, input]

      true ->
        raise "Couldn't parse URI: #{input}"
    end
  end

  defp parse_input(input) when is_list(input) do
    input
  end

  defp parse_output(output) when is_binary(output) do
    uri = URI.new!(output)

    if uri.scheme == nil and Path.extname(uri.path) == ".mp4" do
      [:file, :mp4, uri.path]
    else
      raise "Couldn't parse URI: #{output}"
    end
  end

  defp parse_output(input) when is_list(input) do
    input
  end

  # Wait between sending the last packet
  # and terminating boombox, to avoid closing
  # any connection before the other peer
  # receives the last packet.
  defp wait_before_closing() do
    Process.sleep(500)
  end
end
