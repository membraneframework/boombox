![boombox_transparent](https://github.com/user-attachments/assets/1c5f25a2-cc27-4349-ae72-91315d43d6a1)

This package is a Python API of Boombox - a high-level tool for audio & video streaming tool based on the [Membrane Framework](https://membrane.stream).
For more comprehensive overview, check the [documentation](https://boombox.readthedocs.io).

## Example usage
The following example will read the MP4 file from the provided URL, flip the video and save it to
`output.mp4`

```python
boombox1 = Boombox(
input="https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun33s.mp4",
output=Array(video=True, audio=True),
)
boombox2 = Boombox(input=Array(video=True, audio=True), output="output.mp4")
for b in boombox1.read():
    if isinstance(b, VideoPacket):
        b.payload = np.flip(b.payload, axis=0)
    boombox2.write(b)
boombox2.close(wait=True)
```

## Authors

Boombox is created by Software Mansion.

Since 2012 [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox) is a software agency with experience in building web and mobile apps as well as complex multimedia solutions. We are Core React Native Contributors and experts in live streaming and broadcasting technologies. We can help you build your next dream product – [Hire us](https://swmansion.com/contact/projects).

Copyright 2024, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=boombox)

Licensed under the [Apache License, Version 2.0](LICENSE)
