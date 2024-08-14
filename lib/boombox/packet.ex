defmodule Boombox.Packet do
  @moduledoc """
  Data structure emitted and accepted by `Boombox.run/1`
  when using `:stream` input or output.
  """

  @typedoc @moduledoc
  @type t :: %__MODULE__{
          payload: payload(),
          pts: Membrane.Time.t(),
          kind: :audio | :video
        }

  @type payload :: Vix.Vips.Image.t() | binary()

  @enforce_keys [:payload, :pts, :kind]
  defstruct @enforce_keys

  @spec update_payload(t(), (payload() -> payload())) :: t()
  def update_payload(packet, fun) do
    %__MODULE__{packet | payload: fun.(packet.payload)}
  end
end
