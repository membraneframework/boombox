defmodule Boombox.InternalBin.Pad do
  @moduledoc false

  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad

  alias Boombox.InternalBin.{Ready, State, Wait}
  alias Membrane.Bin.{Action, CallbackContext}
  alias Membrane.Connector

  @type new_tracks_notification_status ::
          :not_resolved
          | :maybe_will_be_sent
          | :sent
          | :never_sent_in_script
          | :never_sent_in_bin

  #                        used in Boombox.run/2
  # :not_resolved -----------------------------------> :never_sent_in_script
  #   |
  #   | membrane_pad option?
  #   | (== boombox.bin)
  #   |
  #   \/                      pads are linked before playing
  # :maybe_will_be_sent ------------------------------------------> :never_sent_in_bin
  #   |
  #   | no pads linked before playing
  #   |
  #   \/
  #  :sending
  #   |
  #   |
  #   \/
  # :sent

  # should be executed:
  # - on init
  # - on pad added
  # - on playback changed
  def resolve_new_tracks_notification_status(%Boombox.InternalBin.State{} = state, ctx) do
    {actions, status} =
      case state.new_tracks_notification_status do
        :not_resolved when state.input == :membrane_pad or state.output == :membrane_pad ->
          {[], :maybe_will_be_sent}

        :not_resolved ->
          {[], :never_sent_in_script}

        :maybe_will_be_sent when ctx.playback == :stopped and map_size(ctx.pads) > 0 ->
          {[], :never_sent_in_bin}

        :maybe_will_be_sent when ctx.playback == :playing and map_size(ctx.pads) == 0 ->
          # todo: resolve tracks
          actions = [notify_parent: {:new_tracks, []}]
          {actions, :sent}

        status when status in [:never_sent_in_script, :never_sent_in_bin, :sent] ->
          {[], status}
      end

    state = %{state | new_tracks_notification_status: status}
    {actions, state}
  end

  @spec handle_pad_added(Membrane.Pad.ref(), :audio | :video, CallbackContext.t()) ::
          [Action.t()] | no_return()
  def handle_pad_added(pad_ref, kind, ctx, state) do
    {new_tracks_actions, state} = resolve_new_tracks_notification_status(state, ctx)

    # todo: refactor error message
    if ctx.playback == :playing and state.new_tracks_notification_status != :sent do
      raise """
      Boombox.InternalBin pad #{inspect(pad_ref)} was added while the Boombox.InternalBin playback \
      is already :playing. All Boombox.InternalBin pads have to be linked before it enters \
      :playing playback. To achieve it, link all the pads of Boombox.InternalBin in the same \
      spec where you spawn it.
      """
    end

    spec =
      case Pad.name_by_ref(pad_ref) do
        :input ->
          bin_input(pad_ref)
          |> child({:pad_connector, :input, kind}, Connector)

        :output ->
          child({:pad_connector, :output, kind}, Connector)
          |> bin_output(pad_ref)
      end

    {new_tracks_actions ++ [spec: spec], state}
  end

  @spec create_input(CallbackContext.t()) :: Ready.t() | Wait.t() | no_return()
  def create_input(ctx) when ctx.playback == :playing and ctx.pads == %{} do
    raise """
    Cannot create input of type #{inspect(__MODULE__)}, as there are no pads available. \
    Link pads to Boombox.InternalBin or set the `:input` option to fix this error.
    """
  end

  def create_input(ctx) when ctx.playback == :playing do
    track_builders =
      ctx.pads
      |> Enum.flat_map(fn
        {Pad.ref(:input, _id), %{options: %{kind: kind}}} ->
          [{kind, get_child({:pad_connector, :input, kind})}]

        {Pad.ref(:output, _id), _pad_data} ->
          []
      end)
      |> Map.new()

    %Ready{track_builders: track_builders}
  end

  def create_input(ctx) when ctx.playback == :stopped do
    %Wait{}
  end

  @spec link_output(
          CallbackContext.t(),
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          Boombox.InternalBin.State.t()
        ) :: Ready.t() | Wait.t()
  def link_output(ctx, track_builders, spec_builder, state) when ctx.playback == :playing do
    validate_pads_and_tracks!(ctx, track_builders)

    linked_tracks =
      track_builders
      |> Enum.map(fn {kind, builder} ->
        pad_options =
          ctx.pads
          |> Enum.find_value(fn
            {Pad.ref(:output, _id), %{options: %{kind: ^kind} = options}} -> options
            _pad_entry -> nil
          end)

        builder
        |> child(%Membrane.Transcoder{
          output_stream_format: &resolve_stream_format(&1, pad_options, state),
          transcoding_policy: pad_options.transcoding_policy
        })
        |> get_child({:pad_connector, :output, kind})
      end)

    spec = [spec_builder, linked_tracks]
    %Ready{actions: [spec: spec]}
  end

  def link_output(ctx, _track_builder, _spec_builder, _state) when ctx.playback == :stopped do
    %Wait{}
  end

  defp resolve_stream_format(%input_codec{}, %{kind: pad_kind, codec: pad_codec}, state) do
    default_codec =
      case pad_kind do
        :audio -> if webrtc_input?(state), do: Membrane.Opus, else: Membrane.AAC
        :video -> Membrane.H264
      end

    pad_codecs = Bunch.listify(pad_codec || default_codec)

    if input_codec in pad_codecs,
      do: input_codec,
      else: List.first(pad_codecs)
  end

  defp validate_pads_and_tracks!(ctx, track_builders) do
    output_pads =
      ctx.pads
      |> Enum.filter(fn {Pad.ref(name, _id), _data} ->
        name == :output
      end)
      |> Map.new(fn {pad_ref, %{options: %{kind: kind}}} ->
        {kind, pad_ref}
      end)

    raise_if_key_not_present(track_builders, output_pads, fn kind ->
      "Boombox.Bin has no output pad of kind #{inspect(kind)}, but it has a track \
      of this kind. Please add an output pad of this kind to the Boombox.Bin."
    end)

    raise_if_key_not_present(output_pads, track_builders, fn kind ->
      "Boombox.Bin has no track of kind #{inspect(kind)}, but it has an output pad \
      of this kind. Please add a track of this kind to the Boombox.Bin."
    end)
  end

  defp raise_if_key_not_present(map_from, map_in, error_log_generator) do
    map_from
    |> Enum.each(fn {kind, _value} ->
      if not is_map_key(map_in, kind) do
        raise error_log_generator.(kind)
      end
    end)
  end

  defp webrtc_input?(state) do
    case state.input do
      {:webrtc, _signaling} -> true
      {:webrtc, _signaling, _opts} -> true
      _other -> false
    end
  end
end
