from setuptools import Extension, setup

# This empty C file is only so that when building wheels they are built for the
# specific platform
setup(
    ext_modules=[
        Extension("guard", ["src/boombox/guard.c"]),
    ],
)
