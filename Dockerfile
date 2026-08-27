# Woodpecker CI agent, prepared for Railway.
#
# Railway blocks unshare(2), so no container runtime can run inside a service and
# the agent's Docker and Kubernetes backends are unavailable. The Local backend is
# the one Woodpecker ships that works here: pipeline steps run as plain processes
# on this container. That needs a shell, a git toolchain and the `plugin-git`
# clone binary, none of which the published agent image carries.
FROM woodpeckerci/woodpecker-agent:v3-alpine

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

# Railway probes this; the agent serves /healthz on it.
ENV PORT=3000
EXPOSE 3000
