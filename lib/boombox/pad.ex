defmodule Boombox.Pad do
  @moduledoc false

  import Membrane.ChildrenSpec

  alias Boombox.Bin.{Ready, Wait}
  alias Membrane.Bin.CallbackContext
  alias Membrane.Connector

  require Membrane.Pad

  @spec handle_pad_added(Membrane.Pad.ref(), CallbackContext.t()) :: Wait.t() | no_return()
  def handle_pad_added(_pad_ref, ctx) when ctx.playback == :playing do
    raise "error"
  end

  def handle_pad_added(pad_ref, _ctx) do
    spec =
      bin_input(pad_ref)
      |> child({:pad_connector, pad_ref}, Connector)

    %Wait{actions: [spec: spec]}
  end

  @spec handle_playing(CallbackContext.t()) :: Ready.t() | no_return()
  def handle_playing(ctx) when ctx.pads == %{} do
    raise "error"
  end

  def handle_playing(ctx) do
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
end
