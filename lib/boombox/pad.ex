defmodule Boombox.Pad do
  @moduledoc false

  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Boombox.InternalBin.{Ready, Wait}
  alias Membrane.Bin.{Action, CallbackContext}
  alias Membrane.Connector

  @spec handle_pad_added(Membrane.Pad.ref(), CallbackContext.t()) :: [Action.t()] | no_return()
  def handle_pad_added(pad_ref, ctx) when ctx.playback == :playing do
    raise """
    Boombox.Bin pad #{inspect(pad_ref)} was added while the Boombox.Bin playback \
    is already :playing. All Boombox.Bin pads have to be linked before it enters \
    :playing playback. To achieve it, link all the pads of Boombox.Bin in the same \
    spec where you spawn it.
    """
  end

  def handle_pad_added(pad_ref, _ctx) do
    spec =
      bin_input(pad_ref)
      |> child({:pad_connector, pad_ref}, Connector)

    [spec: spec]
  end

  @spec create_input(CallbackContext.t()) :: Ready.t() | Wait.t() | no_return()
  def create_input(ctx) when ctx.playback == :playing and ctx.pads == %{} do
    raise """
    Cannot create input of type #{inspect(__MODULE__)}, as there are no pads available. \
    Link pads to Boombox.Bin or set the `:input` option to fix this error.
    """
  end

  def create_input(ctx) when ctx.playback == :playing do
    track_builders =
      ctx.pads
      |> Map.new(fn {pad_ref, _pad_data} ->
        kind =
          case Membrane.Pad.name_by_ref(pad_ref) do
            :video_input -> :video
            :audio_input -> :audio
          end

        {kind, get_child({:pad_connector, pad_ref})}
      end)

    %Ready{track_builders: track_builders}
  end

  def create_input(ctx) when ctx.playback == :stopped do
    %Wait{}
  end
end
