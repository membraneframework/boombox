MIX_ENV=prod BOOMBOX_BURRITO=true mix release --overwrite && \
mv burrito_out/boombox_current boombox && \
rm -r burrito_out && \
yes | ./boombox maintenance uninstall
