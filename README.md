![boombox_horizontal](https://github.com/user-attachments/assets/3e0adc4e-9702-47c3-b3ac-561c0575c17b)


[![Hex.pm](https://img.shields.io/hexpm/v/boombox.svg)](https://hex.pm/packages/boombox)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/boombox)
[![CircleCI](https://circleci.com/gh/membraneframework/boombox.svg?style=svg)](https://circleci.com/gh/membraneframework/boombox)

Boombox is a high-level tool for audio & video streaming tool based on the [Membrane Framework](https://membrane.stream).

See [examples.livemd](examples.livemd) for examples.

## Usage

The code below receives a stream via RTMP and sends it over HLS:

```elixir
Boombox.run(input: "rtmp://localhost:5432", output: "index.m3u8")
```

you can use CLI interface too:

```sh
boombox -i "rtmp://localhost:5432" -o "index.m3u8"
```

And the code below generates a video with bouncing Membrane logo and sends it over WebRTC:

```elixir
Mix.install([:boombox, :req, :image])

overlay =
  Req.get!("https://avatars.githubusercontent.com/u/25247695?s=200&v=4").body
  |> Vix.Vips.Image.new_from_buffer()
  |> then(fn {:ok, img} -> img end)
  |> Image.trim!()
  |> Image.thumbnail!(100)

bg = Image.new!(640, 480, color: :light_gray)
max_x = Image.width(bg) - Image.width(overlay)
max_y = Image.height(bg) - Image.height(overlay)

Stream.iterate({_x = 300, _y = 0, _dx = 1, _dy = 2, _pts = 0}, fn {x, y, dx, dy, pts} ->
  dx = if (x + dx) in 0..max_x, do: dx, else: -dx
  dy = if (y + dy) in 0..max_y, do: dy, else: -dy
  pts = pts + div(Membrane.Time.seconds(1), _fps = 60)
  {x + dx, y + dy, dx, dy, pts}
end)
|> Stream.map(fn {x, y, _dx, _dy, pts} ->
  img = Image.compose!(bg, overlay, x: x, y: y)
  %Boombox.Packet{kind: :video, payload: img, pts: pts}
end)
|> Boombox.run(
  input: {:stream, video: :image, audio: false},
  output: {:webrtc, "ws://localhost:8830"}
)
```

To receive WebRTC/HLS from boombox in a browser or send WebRTC from a browser to boombox
you can use simple HTML examples in the `boombox_examples_data` folder, for example

```sh
wget https://raw.githubusercontent.com/membraneframework/boombox/v0.1.0/boombox_examples_data/webrtc_to_browser.html
open webrtc_to_browser.html
```

For more examples, see [examples.livemd](examples.livemd).

## Supported formats & protocols

| format | input | output |
|---|---|---|
| MP4 | `"*.mp4"` | `"*.mp4"` |
| WebRTC | `{:webrtc, signaling}` | `{:webrtc, signaling}` |
| RTMP | `"rtmp://*"` | _not supported_ |
| RTSP | `"rtsp://*"` | _not supported_ |
| HLS | _not supported_ | `"*.m3u8"` |
| `Enumerable.t()` | `{:stream, opts}` | `{:stream, opts}` |

For the full list of input and output options, see [`Boombox.run/2`](https://hexdocs.pm/boombox/Boombox.html#run/2)

## Installation

To use Boombox as an Elixir library, add

```elixir
{:boombox, "~> 0.1.0"}
```

to your dependencies or `Mix.install`.

to use via CLI, run the following:

```sh
wget https://raw.githubusercontent.com/membraneframework/boombox/v0.1.0/bin/boombox
chmod u+x boombox
./boombox
```

Make sure you have [Elixir](https://elixir-lang.org/) installed. The first call to `boombox` will install it in a default directory in the system. The directory can be set with `MIX_INSTALL_DIR` env variable if preferred.

## CLI

The CLI API is similar to the Elixir API, for example:

```elixir
Boombox.run(input: "file.mp4", output: {:webrtc, "ws://localhost:8830"})
```

is equivalent to:

```sh
./boombox -i file.mp4 -o --webrtc ws://localhost:8830
```

It's also possible to pass an `.exs` script:

```sh
./boombox -s script.exs
```

In the script you can call `Boombox.run(...)` and execute other Elixir code.

The first run of the CLI may take longer than usual, as the necessary artifacts are installed in the system.

## Authors

Boombox is created by Software Mansion.

Since 2012 [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox) is a software agency with experience in building web and mobile apps as well as complex multimedia solutions. We are Core React Native Contributors and experts in live streaming and broadcasting technologies. We can help you build your next dream product – [Hire us](https://swmansion.com/contact/projects).

Copyright 2024, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox)

Licensed under the [Apache License, Version 2.0](LICENSE)
