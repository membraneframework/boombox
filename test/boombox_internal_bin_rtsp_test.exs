defmodule Boombox.InternalBin.RTSPTest do
  use ExUnit.Case, async: true

  alias Boombox.InternalBin.RTSP
  alias Boombox.InternalBin.Wait

  @uri URI.parse("rtsp://example.org/stream")

  describe "create_input/2" do
    test "defaults to video + audio when an empty keyword list is given" do
      assert %Wait{actions: [spec: spec]} = RTSP.create_input(@uri, [])
      assert allowed_media_types(spec) == [:video, :audio]
    end

    test "threads allowed_media_types through to the RTSP source" do
      assert %Wait{actions: [spec: spec]} =
               RTSP.create_input(@uri, allowed_media_types: [:video])

      assert allowed_media_types(spec) == [:video]
    end
  end

  defp allowed_media_types(%Membrane.ChildrenSpec.Builder{} = spec) do
    [{:rtsp_source, %Membrane.RTSP.Source{allowed_media_types: types}, _opts}] = spec.children
    types
  end
end
