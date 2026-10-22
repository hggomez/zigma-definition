# The frontend service of docker-compose.yml: nginx serving the pages
# generated from the SSOT (written into public/ on the host by `zig build`:
# no Zig in the image) and proxying /api to the backend.
FROM nginx:1.28.0-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public /usr/share/nginx/html
