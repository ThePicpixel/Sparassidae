ARG FLUENTD_VERSION=v1.17-1
FROM fluent/fluentd:${FLUENTD_VERSION}

USER root

# fluent-plugin-elasticsearch pulls in the pure-Ruby elasticsearch client.
# build-base/ruby-dev are only needed while native extensions compile, so they
# go into a virtual package and get dropped again.
#
# fluent-plugin-elasticsearch 5.4.x puts no upper bound on the elasticsearch
# gem, so it grabs the latest client -- which since 9.x lockstep-versions with
# the product and unconditionally rewrites bulk request headers to
# "compatible-with=9" on both Content-Type and Accept. That collides with the
# plugin's own header handling and Elasticsearch 9 rejects the mangled
# request with 400 media_type_header_exception. The 8.x client line doesn't
# have that rewrite and is fully REST-compatible with a 9.x server, so pin to
# it explicitly and drop whatever 9.x version got installed as a dependency.
RUN apk add --no-cache --virtual .build-deps build-base ruby-dev \
    && gem install fluent-plugin-elasticsearch --no-document -v '~> 5.4' \
    && gem uninstall elasticsearch elasticsearch-api elastic-transport --all --force --ignore-dependencies \
    && gem install elasticsearch --no-document -v '~> 8.19' \
    && gem sources --clear-all \
    && apk del .build-deps \
    && rm -rf /tmp/* /var/tmp/* /usr/lib/ruby/gems/*/cache/*.gem

# Create the buffer dir in the image so the named volume inherits the right
# ownership on first mount; otherwise Docker creates it root-owned and the
# unprivileged fluent user cannot write buffers.
RUN mkdir -p /fluentd/buffer && chown -R fluent:fluent /fluentd/buffer

USER fluent
