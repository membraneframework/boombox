# Boombox

[![Hex.pm](https://img.shields.io/hexpm/v/boombox.svg)](https://hex.pm/packages/boombox)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/boombox)
[![CircleCI](https://circleci.com/gh/membraneframework/boombox.svg?style=svg)](https://circleci.com/gh/membraneframework/boombox)

Boombox is a powerful tool for audio & video streaming based on the [Membrane Framework](https://membrane.stream).

## Installation

The package can be installed by adding `boombox` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:boombox, "~> 0.1.0"}
  ]
end
```

## Usage

See `examples.livemd` for usage examples.

## CLI app

To build a CLI app, clone the repo and run

```
mix deps.get
./build_binary.sh
```

It should generate a single executable called `boombox`, which you can run.

The CLI API is similar to the Elixir API, for example:

```elixir
Boombox.run(input: "file.mp4", output: {:webrtc, "ws://localhost:8830"})
```

is equivalent to:

```
./boombox -i file.mp4 -o --webrtc ws://localhost:8830
```

It's also possible to pass an `.exs` script:

```
./boombox -S script.exs
```

In the script you can call `Boombox.run(...)` and execute other Elixir code.

The first run of the CLI may take longer than usual, as the necessary artifacts are installed in the system.

## Copyright and License

Copyright 2020, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox)

Licensed under the [Apache License, Version 2.0](LICENSE)
