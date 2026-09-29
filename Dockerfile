FROM dart:stable
RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
  && ln -sf "$(find /usr/lib -name 'libsqlite3.so.0' | head -1)" /usr/lib/libsqlite3.so \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --home-dir /home/mcp mcp \
  && mkdir -p /data /home/mcp/.dart-tool \
  && chown -R mcp:mcp /data /home/mcp
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY bin bin
COPY lib lib
COPY tool/docker_entrypoint.sh /usr/local/bin/docker_entrypoint.sh
RUN dart compile exe bin/dart_vm_mcp.dart -o /usr/local/bin/dart_vm_mcp \
  && chmod 755 /usr/local/bin/docker_entrypoint.sh
ENV HOME=/home/mcp
ENV DART_VM_MCP_DATA=/data
ENV DART_VM_MCP_IN_DOCKER=1
ENTRYPOINT ["/usr/local/bin/docker_entrypoint.sh"]
