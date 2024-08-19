MIX_ENV=prod BOOMBOX_BURRITO=true mix release --overwrite && \
mv burrito_out/boombox_current boombox && \
rm -r burrito_out && \
# Burrito extracts the compressed artifacts into a common
# location in the system on a first run, and then reuses
# those artifacts and checks the version in mix.exs to
# know whether it car reuse them. So we need to uninstall
# the artifacts to force burrito to extract them again
# even if the version in mix.exs didn't change
yes | ./boombox maintenance uninstall
