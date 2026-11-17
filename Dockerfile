# The CLI, lifted from its own published image so it floats with the same v3 tag.
# Used by the build-time self-test below, and available to pipelines.
FROM woodpeckerci/woodpecker-cli:v3-alpine@sha256:74c576faf49cce699825d11c7d7bd38ab5f007dd4f57cdbdd55099d2c0f2621a AS cli

# Woodpecker CI agent, prepared for Railway.
#
# Railway blocks unshare(2), so no container runtime can run inside a service and
# the agent's Docker and Kubernetes backends are unavailable. The Local backend is
# the one Woodpecker ships that works here: pipeline steps run as plain processes
# on this container. That needs a shell, a git toolchain and the `plugin-git`
# clone binary, none of which the published agent image carries.
FROM woodpeckerci/woodpecker-agent:v3-alpine@sha256:0b4b0afd7c1ff3e45f918eee16ef3797d710fd9e6ef73525e1a46ba030902777

# The base ends on the alpine image's implicit root, but restate it so the layers
# below are unambiguous if upstream ever adds a USER line.
USER root

# Pinned so the build is reproducible; bump with the upstream plugin-git release.
ARG PLUGIN_GIT_VERSION=2.10.0

# Runner toolchain. Kept to what an ordinary pipeline reaches for on its first
# line — a POSIX shell, git over https and ssh, an archiver, jq, make, Node and
# Python — plus `su-exec`, because BusyBox builds `setpriv` capabilities-only and
# it cannot change uid.
RUN set -eux; \
    apk add --no-cache \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        git \
        git-lfs \
        grep \
        gzip \
        jq \
        make \
        nodejs \
        npm \
        openssh-client \
        openssl \
        python3 \
        py3-pip \
        sed \
        su-exec \
        tar \
        tzdata \
        unzip \
        wget \
        xz; \
    case "$(uname -m)" in \
        x86_64)  PLUGIN_GIT_ARCH=linux-amd64 ;; \
        aarch64) PLUGIN_GIT_ARCH=linux-arm64 ;; \
        armv7l)  PLUGIN_GIT_ARCH=linux-arm ;; \
        *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    wget -qO /usr/local/bin/plugin-git \
        "https://github.com/woodpecker-ci/plugin-git/releases/download/${PLUGIN_GIT_VERSION}/${PLUGIN_GIT_ARCH}_plugin-git"; \
    chmod 0755 /usr/local/bin/plugin-git; \
    git --version; \
    bash --version | head -n 1; \
    command -v plugin-git

# Official Microsoft musl SDK, version and SHA-512 fixed at image build time.
# Alpine dependencies follow Microsoft's supported Linux installation guidance.
ARG DOTNET_SDK_VERSION=10.0.404
ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_NOLOGO=1
RUN set -eux; \
    cat /etc/alpine-release; \
    uname -m; \
    apk add --no-cache icu-libs icu-data-full krb5-libs libgcc libssl3 libstdc++ zlib; \
    case "$(uname -m)" in \
        x86_64) rid=linux-musl-x64; checksum=68ada5fd8fa2b65f55c3db1c2e773dfc9468c9828cbb56fc600151415cc2b116a32804f9aeeb82ca1a3229e3821af7b5b074d5e34487b2807630b5c00f51d801 ;; \
        aarch64) rid=linux-musl-arm64; checksum=b39da19b6134190ed0b9107c05c98c58586f4f77782c4b0e3e36c6274a2d59528f67412c2b0cbb927a914378177f763cb662b435c5bef62ad5c2cd86a422c877 ;; \
        *) echo "unsupported .NET SDK architecture" >&2; exit 1 ;; \
    esac; \
    curl --fail --show-error --location --retry 3 \
        "https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-${rid}.tar.gz" \
        --output /tmp/dotnet-sdk.tar.gz; \
    printf '%s  %s\n' "$checksum" /tmp/dotnet-sdk.tar.gz | sha512sum -c -; \
    mkdir -p "$DOTNET_ROOT"; \
    tar -xzf /tmp/dotnet-sdk.tar.gz -C "$DOTNET_ROOT"; \
    rm /tmp/dotnet-sdk.tar.gz; \
    ln -s "$DOTNET_ROOT/dotnet" /usr/local/bin/dotnet; \
    dotnet --info; \
    dotnet --list-sdks; \
    test "$(dotnet --version)" = "$DOTNET_SDK_VERSION"

# The base image's ENTRYPOINT is ["/bin/woodpecker-agent"] with no CMD. Shim that
# binary rather than declaring an ENTRYPOINT of our own, which would blank the
# inherited CMD and force us to restate a start sequence that then rots against
# the floating v3 tag.
COPY entrypoint.sh /bin/woodpecker-agent.wrapper
RUN set -eux; \
    bash -n /bin/woodpecker-agent.wrapper; \
    mv /bin/woodpecker-agent /bin/woodpecker-agent.real; \
    mv /bin/woodpecker-agent.wrapper /bin/woodpecker-agent; \
    chmod 0755 /bin/woodpecker-agent

COPY --from=cli /bin/woodpecker-cli /usr/local/bin/woodpecker-cli

# Self-test: run a real pipeline through the Local backend, as the unprivileged
# user the agent will run as. A missing shell, a broken plugin-git or a botched
# privilege drop fails the build here instead of crash-looping a container whose
# log shows only an exit code.
RUN set -eux; \
    mkdir -p /tmp/selftest; \
    printf '%s\n' \
        'steps:' \
        '  - name: selftest' \
        '    image: bash' \
        '    commands:' \
        '      - echo "local backend reached"' \
        '      - git --version' \
        '      - node --version' \
        '      - python3 --version' \
        '      - jq --version' \
        '      - command -v plugin-git' \
        '      - bash --version' \
        '      - dotnet --info' \
        '      - dotnet --list-sdks' \
        '      - dotnet --list-sdks | grep -E "^10[.]"' \
        '      - export DOTNET_CLI_HOME=/tmp/selftest/cli NUGET_PACKAGES=/tmp/selftest/packages' \
        '      - dotnet new console --framework net10.0 --no-restore -o /tmp/selftest/app' \
        '      - dotnet restore /tmp/selftest/app --ignore-failed-sources' \
        '      - dotnet build /tmp/selftest/app -c Release --no-restore -m:1 -p:UseSharedCompilation=false' \
        > /tmp/selftest/.woodpecker.yaml; \
    chown -R 1000:1000 /tmp/selftest; \
    cd /tmp/selftest; \
    su-exec 1000:1000 woodpecker-cli exec --backend-engine local --local .woodpecker.yaml; \
    rm -rf /tmp/selftest

# Railway probes this; the agent serves /healthz on it.
ENV PORT=3000
EXPOSE 3000
