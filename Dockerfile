FROM docker.io/xinnj/file-server:base

RUN apk add --no-cache lua5.1-cjson luarocks5.1 lua5.1-filesystem
RUN luarocks-5.1 install lua-resty-string \
    && luarocks-5.1 install lua-resty-redis \
    && luarocks-5.1 install lua-resty-openidc

COPY nginx.conf /etc/nginx/
COPY auth_config.json /source/
COPY lua-lib/ /usr/local/share/lua/5.1/
COPY lua /etc/nginx/lua
COPY fileserver /source/fileserver
COPY /house-keeping/Clean.sh /
COPY Start.sh /

RUN chmod +x /*.sh

VOLUME /data
ENV URL_PREFIX="/"
ENV LOGO_TEXT="My Files"

CMD /Start.sh
