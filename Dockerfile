# docker.io/xinnj/file-server

FROM docker.io/xinnj/file-server:base

RUN apk add --no-cache bash lua5.1-cjson luarocks5.1
RUN luarocks-5.1 install lua-resty-string \
    && luarocks-5.1 install lua-resty-redis \
    && luarocks-5.1 install lua-resty-openidc

COPY nginx.conf /etc/nginx/
COPY auth_config.json /source/
COPY lua-lib/ /usr/local/share/lua/5.1/
COPY lua /etc/nginx/lua
COPY fileserver /source/fileserver
COPY --chmod=755 /house-keeping/Clean.sh /
COPY --chmod=755 Start.sh /

VOLUME /data
ENV URL_PREFIX="/"

CMD /Start.sh
