defmodule Boombox.InternalBin do
    @moduledoc """
    TODO: write docs
    """
    use Membrane.Bin

    require Membrane.Logger
    require Membrane.Transcoder.Audio
    require Membrane.Transcoder.Video
    alias Membrane.Transcoder

    @type input() ::
            (path_or_uri :: String.t())
            | {:mp4, location :: String.t(), transport: :file | :http}
            | {:webrtc, Boombox.webrtc_signaling()}
            | {:whip, uri :: String.t(), token: String.t()}
            | {:rtmp, (uri :: String.t()) | (client_handler :: pid)}
            | {:rtsp, url :: String.t()}
            | {:rtp, Boombox.in_rtp_opts()}
            | {:stream, pid(), Boombox.in_stream_opts()}
            | :membrane_pad

    @type output ::
            (path_or_uri :: String.t())
            | {path_or_uri :: String.t(), [Boombox.force_transcoding()]}
            | {:mp4, location :: String.t()}
            | {:mp4, location :: String.t(), [Boombox.force_transcoding()]}
            | {:webrtc, Boombox.webrtc_signaling()}
            | {:webrtc, Boombox.webrtc_signaling(), [Boombox.force_transcoding()]}
            | {:whip, uri :: String.t(), [{:token, String.t()} | {bandit_option :: atom(), term()}]}
            | {:hls, location :: String.t()}
            | {:hls, location :: String.t(), [Boombox.force_transcoding()]}
            | {:rtp, Boombox.out_rtp_opts()}
            | {:stream, pid(), Boombox.out_stream_opts()}

    @type track_builders :: %{
            optional(:audio) => Membrane.ChildrenSpec.t(),
            optional(:video) => Membrane.ChildrenSpec.t()
          }
    @type storage_type :: :file | :http

    defmodule Ready do
      @moduledoc false

      @type t :: %__MODULE__{
              actions: [Membrane.Bin.Action.t()],
              track_builders: Boombox.Bin.track_builders() | nil,
              spec_builder: Membrane.ChildrenSpec.t() | nil,
              eos_info: term
            }

      defstruct actions: [], track_builders: nil, spec_builder: [], eos_info: nil
    end

    defmodule Wait do
      @moduledoc false

      @type t :: %__MODULE__{actions: [Membrane.Bin.Action.t()]}
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
                    rtsp_state: nil,
                    pending_new_tracks: %{input: [], output: []},
                    output_webrtc_state: nil
                  ]

      @typedoc """
      Statuses of the Boombox.Bin in the order of occurence.

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
              input: Boombox.Bin.input(),
              output: Boombox.Bin.output(),
              actions_acc: [Membrane.Bin.Action.t()],
              spec_builder: Membrane.ChildrenSpec.t(),
              track_builders: Boombox.Bin.track_builders() | nil,
              last_result: Ready.t() | Wait.t() | nil,
              eos_info: term(),
              rtsp_state: Boombox.RTSP.state() | nil,
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

    def_options input: [spec: input() | :membrane_pad],
                output: [spec: output()]

    @impl true
    def handle_init(ctx, opts) do
      state = %State{
        input: parse_endpoint_opt!(:input, opts.input),
        output: parse_endpoint_opt!(:output, opts.output),
        status: :init
      }

      :ok = maybe_log_transcoding_related_warning(state.input, state.output)
      proceed(ctx, state)
    end

    @impl true
    def handle_playing(ctx, state) when state.input == :membrane_pad do
      cond do
        state.status in [:init, :awaiting_output] ->
          {[], state}

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
    def handle_pad_added(pad_ref, _ctx, state) do
      raise """
      Tried to link pad #{inspect(pad_ref)}, while input was set to #{inspect(state.input)}. \
      It is not possible to set `:input` option and link input pads of #{inspect(__MODULE__)} \
      at the same time.
      """
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
            Membrane.Bin.callback_return()
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
            Membrane.Bin.callback_return()
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
          ) :: Membrane.Bin.callback_return()
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

    @spec create_input(input(), Membrane.Bin.CallbackContext.t(), State.t()) ::
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

    defp create_input({:stream, stream_process, params}, _ctx, _state) do
      Boombox.ElixirStream.create_input(stream_process, params)
    end

    defp create_input(:membrane_pad, ctx, _state) do
      Boombox.Pad.create_input(ctx)
    end

    @spec create_output(output(), Membrane.Bin.CallbackContext.t(), State.t()) ::
            {Ready.t() | Wait.t(), State.t()}
    defp create_output({:webrtc, signaling, _opts}, ctx, state) do
      Boombox.WebRTC.create_output(signaling, ctx, state)
    end

    defp create_output(_output, _ctx, state) do
      {%Ready{}, state}
    end

    @spec link_output(
            output(),
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

    defp link_output({:stream, stream_process, opts}, track_builders, spec_builder, _ctx, _state) do
      Boombox.ElixirStream.link_output(
        stream_process,
        opts,
        track_builders,
        spec_builder
      )
    end

    # Wait between sending the last packet
    # and terminating boombox, to avoid closing
    # any connection before the other peer
    # receives the last packet.
    defp wait_before_closing() do
      Process.sleep(500)
    end

    @spec parse_endpoint_opt!(:input, input() | :membrane_pad) ::
            input() | :membrane_pad
    @spec parse_endpoint_opt!(:output, output() | :membrane_pad) ::
            output() | :membrane_pad
    defp parse_endpoint_opt!(direction, value) when is_binary(value) do
      parse_endpoint_opt!(direction, {value, []})
    end

    defp parse_endpoint_opt!(direction, {value, opts}) when is_binary(value) do
      uri = URI.parse(value)
      scheme = uri.scheme
      extension = if uri.path, do: Path.extname(uri.path)

      case {scheme, extension, direction} do
        {scheme, ".mp4", :input} when scheme in [nil, "http", "https"] -> {:mp4, value, opts}
        {nil, ".mp4", :output} -> {:mp4, value, opts}
        {scheme, _ext, :input} when scheme in ["rtmp", "rtmps"] -> {:rtmp, value}
        {"rtsp", _ext, :input} -> {:rtsp, value}
        {nil, ".m3u8", :output} -> {:hls, value, opts}
        _other -> raise ArgumentError, "Unsupported URI: #{value} for direction: #{direction}"
      end
      |> then(&parse_endpoint_opt!(direction, &1))
    end

    # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
    defp parse_endpoint_opt!(direction, value) when is_tuple(value) or is_atom(value) do
      case value do
        {:mp4, location} when is_binary(location) and direction == :input ->
          parse_endpoint_opt!(:input, {:mp4, location, []})

        {:mp4, location, opts} when is_binary(location) and direction == :input ->
          opts = opts |> Keyword.put(:transport, resolve_transport(location, opts))
          {:mp4, location, opts}

        {:mp4, location} when is_binary(location) and direction == :output ->
          {:mp4, location, []}

        {:mp4, location, _opts} when is_binary(location) and direction == :output ->
          value

        {:webrtc, %Membrane.WebRTC.Signaling{}} when direction == :input ->
          value

        {:webrtc, %Membrane.WebRTC.Signaling{} = signaling} ->
          {:webrtc, signaling, []}

        {:webrtc, %Membrane.WebRTC.Signaling{}, _opts} when direction == :output ->
          value

        {:webrtc, uri} when is_binary(uri) and direction == :input ->
          value

        {:webrtc, uri} when is_binary(uri) and direction == :output ->
          {:webrtc, uri, []}

        {:webrtc, uri, _opts} when is_binary(uri) and direction == :output ->
          value

        {:whip, uri} when is_binary(uri) ->
          parse_endpoint_opt!(direction, {:whip, uri, []})

        {:whip, uri, opts} when is_binary(uri) and is_list(opts) and direction == :input ->
          if Keyword.keyword?(opts), do: {:webrtc, value}

        {:whip, uri, opts} when is_binary(uri) and is_list(opts) and direction == :output ->
          {webrtc_opts, whip_opts} = split_webrtc_and_whip_opts(opts)
          if Keyword.keyword?(opts), do: {:webrtc, {:whip, uri, whip_opts}, webrtc_opts}

        {:rtmp, arg} when direction == :input and (is_binary(arg) or is_pid(arg)) ->
          value

        {:hls, location} when direction == :output and is_binary(location) ->
          {:hls, location, []}

        {:hls, location, opts}
        when direction == :output and is_binary(location) and is_list(opts) ->
          value

        {:rtsp, location} when direction == :input and is_binary(location) ->
          value

        {:rtp, opts} ->
          if Keyword.keyword?(opts), do: value

        {:stream, _stream_process, opts} ->
          if Keyword.keyword?(opts), do: value

        :membrane_pad ->
          :membrane_pad

        _other ->
          nil
      end
      |> case do
        nil -> raise ArgumentError, "Invalid #{direction} specification: #{inspect(value)}"
        value -> value
      end
    end

    @spec resolve_transport(String.t(), [{:transport, :file | :http}]) :: :file | :http
    defp resolve_transport(location, opts) do
      case Keyword.validate!(opts, transport: nil, force_transcoding: false)[:transport] do
        nil ->
          uri = URI.parse(location)

          case uri.scheme do
            nil -> :file
            "http" -> :http
            "https" -> :http
            _other -> raise ArgumentError, "Unsupported URI: #{location}"
          end

        transport when transport in [:file, :http] ->
          transport

        transport ->
          raise ArgumentError, "Invalid transport: #{inspect(transport)}"
      end
    end

    defp split_webrtc_and_whip_opts(opts) do
      opts
      |> Enum.split_with(fn {key, _value} -> key == :force_transcoding end)
    end

    @spec maybe_log_transcoding_related_warning(input(), output()) :: :ok
    defp maybe_log_transcoding_related_warning(input, output) do
      if elem(output, 0) == :webrtc and elem(input, 0) not in [:webrtc, :stream] and
           webrtc_output_force_transcoding(output) not in [true, :video] do
        Membrane.Logger.warning("""
        Boombox output protocol is WebRTC, while Boombox input doesn't support keyframe requests. This \
        might lead to issues with the output video if the output stream isn't sent only by localhost. You \
        can solve this by setting `:force_transcoding` output option to `true` or `:video`, but be aware \
        that it will increase Boombox CPU usage.
        """)
      end

      :ok
    end

    defp webrtc_output_force_transcoding({:webrtc, _singaling, opts}),
      do: Keyword.get(opts, :force_transcoding)
end
