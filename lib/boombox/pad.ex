defmodule Boombox.Pad do
  @moduledoc false

  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad

  alias Boombox.InternalBin.{Ready, Wait}
  alias Membrane.Bin.{Action, CallbackContext}
  alias Membrane.Connector

  @spec handle_pad_added(Membrane.Pad.ref(), :audio | :video, CallbackContext.t()) ::
          [Action.t()] | no_return()
  def handle_pad_added(pad_ref, _kind, ctx) when ctx.playback == :playing do
    raise """
    Boombox.InternalBin pad #{inspect(pad_ref)} was added while the Boombox.InternalBin playback \
    is already :playing. All Boombox.InternalBin pads have to be linked before it enters \
    :playing playback. To achieve it, link all the pads of Boombox.InternalBin in the same \
    spec where you spawn it.
    """
  end

  def handle_pad_added(pad_ref, kind, _ctx) do
    spec =
      case Pad.name_by_ref(pad_ref) do
        :input ->
          bin_input(pad_ref)
          |> child({:pad_connector, :input, kind}, Connector)

        :output ->
          child({:pad_connector, :output, kind}, Connector)
          |> bin_output(pad_ref)
      end

    [spec: spec]
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
