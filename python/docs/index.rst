.. boombox documentation master file, created by
   sphinx-quickstart on Tue May 20 21:43:49 2025.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

Boombox
=====================

This package is a Python API of Boombox - a high-level tool for audio & video streaming tool based
on the `Membrane Framework <https://membrane.stream>`_. Boombox allows for transforming one stream
format into another using a simple declarative interface. It also allows for interacting with the
media directly in the code, for example modifying video streams with AI.

To transform a stream started simply create a :py:class:`.Boombox` object with desired input and
output, which are defined through :py:mod:`.endpoints`. For example::

    from boombox import Boombox, MP4, RTMP

    boombox = Boombox(
        input=RTMP("rtmp://my.stream.source:2137/app/key"),
        output=MP4("path/to/target.mp4")
    )
    boombox.wait()

When this code is run, Boombox will become a RTMP server, wait for clients to connect and save
the acquired stream to a ``.mp4`` file at the provided location.

To interact with raw media in the code, the :py:class:`.RawData` endpoint can be used. Boombox will
then produce or accept packets of raw media data. These packets are :py:class:`.AudioPacket` and
:py:class:`.VideoPacket` objects.

You can define a :py:class:`.RawData` output and read the stream through a generator::

    boombox = Boombox(
        input=any_input_endpoint
        output=RawData(video=True, audio=True)
    )

    for packet in boombox.read():
        process_packet(packet)

Or define a :py:class:`.RawData` output and write packets to Boombox with :py:meth:`.Boombox.write`::

    with Boombox(
        input=RawData(video=True, audio=True)
        output=any_output_endpoint
    ) as boombox:
        for packet in some_packet_generator():
            boombox.write(packet)

These operations can also be combined - read from boombox, process the stream and write it to
another boombox. A demo showing an example of this can be found
`here <https://https://github.com/membraneframework/boombox/tree/master/python/examples/anonymise_demo.py>`_.
It utilizes AI tools to make a WebRTC stream "anonymous" - it uses multiple AI models to blur
the users face, distorts their voice and transcribes their speech. More details inside the demo.



.. toctree::
   :maxdepth: 2
   :caption: Contents:

   boombox
   boombox_endpoints
