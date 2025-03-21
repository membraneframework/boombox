defmodule Boombox.Pad do
  @moduledoc false

  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Boombox.Bin.{Ready, Wait}
  alias Membrane.Bin.{Action, CallbackContext}
  alias Membrane.Connector

  @spec handle_pad_added(Membrane.Pad.ref(), CallbackContext.t()) :: [Action.t()] | no_return()
  def handle_pad_added(_pad_ref, ctx) when ctx.playback == :playing do
    raise "error pad added too late"
  end

  def handle_pad_added(pad_ref, _ctx) do
    spec =
      bin_input(pad_ref)
      |> child({:pad_connector, pad_ref}, Connector)

    [spec: spec]
  end

  # create_input should be executed:
  #  - after `output_ready`
  #    a. we are in :playing, so we go to `:input_ready`
  #    b. we are in :stopped, so we execute `create_input` in `handle_playing`

  @spec create_input(CallbackContext.t()) :: Ready.t() | Wait.t() | no_return()
  def create_input(ctx) when ctx.playback == :playing and ctx.pads == %{} do
    raise "error no pads"
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
