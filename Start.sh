#!/bin/sh
set -e

if [ -z "$URL_PREFIX" ]; then
  URL_PREFIX="/"
fi

if [ -z "$NGINX_LOG_LEVEL" ]; then
  NGINX_LOG_LEVEL="notice"
fi

mkdir -p /data${URL_PREFIX}download
mkdir -p /data${URL_PREFIX}public
mkdir -p /data${URL_PREFIX}archive
mkdir -p /data/config

cp -rf /source/fileserver /data${URL_PREFIX}

if [ ! -f /data/config/auth_config.json ]; then
  cp /source/auth_config.json /data/config/
  chown -R uploader:uploader /data/config
fi

rm -rf /data${URL_PREFIX}secure-download
ln -sf /data${URL_PREFIX}download /data${URL_PREFIX}secure-download
rm -rf /data${URL_PREFIX}secure-archive
ln -sf /data${URL_PREFIX}archive /data${URL_PREFIX}secure-archive

rm -rf /data${URL_PREFIX}internal-download
ln -sf /data${URL_PREFIX}download /data${URL_PREFIX}internal-download
rm -rf /data${URL_PREFIX}internal-archive
ln -sf /data${URL_PREFIX}archive /data${URL_PREFIX}internal-archive

chown uploader:uploader /data${URL_PREFIX}download
chown uploader:uploader /data${URL_PREFIX}public
chown uploader:uploader /data${URL_PREFIX}archive
chown -R uploader:uploader /data${URL_PREFIX}secure-download
chown -R uploader:uploader /data${URL_PREFIX}secure-archive
chown -R uploader:uploader /data${URL_PREFIX}internal-download
chown -R uploader:uploader /data${URL_PREFIX}internal-archive

export NAMESERVER=$(cat /etc/resolv.conf | grep "nameserver" | awk '{print $2}' | tr '\n' ' ')
sed -i -e "s#<URL_PREFIX>#${URL_PREFIX}#g" \
       -e "s#<NAMESERVER>#${NAMESERVER}#g" \
       -e "s#<NGINX_LOG_LEVEL>#${NGINX_LOG_LEVEL}#g" \
       /etc/nginx/nginx.conf
sed -i -e "s#<URL_PREFIX>#${URL_PREFIX}#g" /data${URL_PREFIX}fileserver/template.html
sed -i -e "s#<URL_PREFIX>#${URL_PREFIX}#g" /data${URL_PREFIX}fileserver/js/app.js
sed -i -e "s#<URL_PREFIX>#${URL_PREFIX}#g" /data${URL_PREFIX}fileserver/js/actions.js
sed -i -e "s#<URL_PREFIX>#${URL_PREFIX}#g" /data${URL_PREFIX}fileserver/js/gen-qrcode.js
sed -i -e "s#<URL_PREFIX>#${URL_PREFIX}#g" /data${URL_PREFIX}fileserver/access-token.html
sed -i -e "s#<URL_PREFIX>#${URL_PREFIX}#g" /data${URL_PREFIX}fileserver/access-control.html
sed -i -e "s#<URL_PREFIX>#${URL_PREFIX}#g" /data${URL_PREFIX}fileserver/share-links.html
sed -i -e "s#<URL_PREFIX>#${URL_PREFIX}#g" /data/config/auth_config.json

/usr/sbin/nginx -g 'daemon off;'