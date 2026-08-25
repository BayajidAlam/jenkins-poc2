# Dockerfile for the Hello World page
# Minimal nginx-based static site. The IMAGE_TAG_PLACEHOLDER and
# DOCKERHUB_USER strings are substituted at build time by the Jenkinsfile
# via sed (since the html file uses no template engine).

FROM nginx:alpine

# Default build args - Jenkinsfile will override these per build
ARG IMAGE_TAG=IMAGE_TAG_PLACEHOLDER
ARG DOCKERHUB_USER=DOCKERHUB_USER

# Copy the static page
COPY index.html /usr/share/nginx/html/index.html

# Substitute placeholders at build time so each tag shows its own values
RUN sed -i "s/IMAGE_TAG_PLACEHOLDER/${IMAGE_TAG}/g"        /usr/share/nginx/html/index.html \
 && sed -i "s/DOCKERHUB_USER/${DOCKERHUB_USER}/g"          /usr/share/nginx/html/index.html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]