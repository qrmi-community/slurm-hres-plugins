FROM rockylinux:9

LABEL org.opencontainers.image.source="https://github.com/giovtorres/slurm-docker-cluster" \
      org.opencontainers.image.title="slurm-docker-cluster" \
      org.opencontainers.image.description="Slurm Docker cluster on Rocky Linux 8" \
      org.label-schema.docker.cmd="docker-compose up -d" \
      maintainer="Giovanni Torres"

RUN set -ex \
    && yum makecache \
    && yum -y update \
    && yum -y install dnf-plugins-core \
    && yum config-manager --set-enabled crb \
    && yum -y install epel-release \
    && yum -y install \
       wget \
       bzip2 \
       perl \
       gcc \
       gcc-c++ \
       gdb \
       git \
       gnupg \
       make \
       munge \
       munge-devel \
       python3.12-devel \
       python3.12-pip \
       mariadb-server \
       mariadb-devel \
       psmisc \
       bash-completion \
       vim-enhanced \
       http-parser-devel \
       json-c-devel \
       libjwt-devel \
       cmake \
       clang-tools-extra \
       procps \
       iputils \
       net-tools \
       openblas-devel \
       jq \
       iputils \
       net-tools \
       libyaml-devel \
       procps \
       lua-devel \
       autoconf \
       libtool \
       flex \
       libevent-devel \
       hwloc-devel \
       valgrind \
    && yum clean all \
    && rm -rf /var/cache/yum

RUN alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1

RUN pip3.12 install Cython pytest

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

ARG GOSU_VERSION=1.17

RUN set -ex \
    && wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-amd64" \
    && wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-amd64.asc" \
    && export GNUPGHOME="$(mktemp -d)" \
    && gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 \
    && gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu \
    && rm -rf "${GNUPGHOME}" /usr/local/bin/gosu.asc \
    && chmod +x /usr/local/bin/gosu \
    && gosu nobody true

ARG OPENPMIx_VERSION=4.1.3

RUN set -euxp pipefail \
    && wget -nv -O pmix-${OPENPMIx_VERSION}.tar.gz https://github.com/openpmix/openpmix/releases/download/v${OPENPMIx_VERSION}/pmix-${OPENPMIx_VERSION}.tar.gz \
    && tar -xvf pmix-${OPENPMIx_VERSION}.tar.gz \
    && pushd pmix-${OPENPMIx_VERSION} \
    && ./configure --prefix=/usr/local/pmix-${OPENPMIx_VERSION} \
    && make all install \
    && popd

ARG SLURM_TAG

RUN set -x \
    && git clone -b ${SLURM_TAG} --single-branch --depth=1 https://github.com/SchedMD/slurm.git \
    && pushd slurm \
    && ./configure --enable-debug --prefix=/usr --sysconfdir=/etc/slurm \
        --with-mysql_config=/usr/bin  --libdir=/usr/lib64 \
        --with-pmix=/usr/local/pmix-${OPENPMIx_VERSION} \
        --enable-slurmrestd --with-jwt \
    && make install \
    && install -D -m644 etc/cgroup.conf.example /etc/slurm/cgroup.conf.example \
    && install -D -m644 etc/slurm.conf.example /etc/slurm/slurm.conf.example \
    && install -D -m644 etc/slurmdbd.conf.example /etc/slurm/slurmdbd.conf.example \
    && install -D -m644 contribs/slurm_completion_help/slurm_completion.sh /etc/profile.d/slurm_completion.sh \
    && popd \
    && groupadd -r --gid=990 slurm \
    && useradd -r -g slurm --uid=990 slurm \
    && groupadd -r --gid=991 slurmrestd \
    && useradd -r -g slurmrestd --uid=991 -s /sbin/nologin slurmrestd \
    && mkdir /etc/sysconfig/slurm \
        /var/spool/slurmd \
        /var/run/slurmd \
        /var/run/slurmdbd \
        /var/lib/slurmd \
        /var/log/slurm \
        /data \
    && touch /var/lib/slurmd/node_state \
        /var/lib/slurmd/front_end_state \
        /var/lib/slurmd/job_state \
        /var/lib/slurmd/resv_state \
        /var/lib/slurmd/trigger_state \
        /var/lib/slurmd/assoc_mgr_state \
        /var/lib/slurmd/assoc_usage \
        /var/lib/slurmd/qos_usage \
        /var/lib/slurmd/fed_mgr_state \
    && chown -R slurm:slurm /var/*/slurm* \
    && /sbin/create-munge-key

# ---------------------------------------------------------------------------
# QRMI for the HRES plugin (qrmi_hres.lua)
#   libqrmi.so -> /usr/local/lib (registered with ldconfig)
#   qrmi.so    -> /usr/lib64/lua/5.4 (in the default package.cpath of the
#                 Rocky 9 Lua 5.4, the same Lua Slurm was built with above)
# ---------------------------------------------------------------------------
ARG QRMI_REF=main

RUN set -ex \
    && yum -y install lua openssl-devel pkgconf-pkg-config \
    && yum clean all \
    && . "$HOME/.cargo/env" \
    && git clone -b ${QRMI_REF} --single-branch --depth=1 https://github.com/qiskit-community/qrmi.git /tmp/qrmi \
    && cd /tmp/qrmi \
    && cargo build --locked --release \
    && install -D -m755 target/release/libqrmi.so /usr/local/lib/libqrmi.so \
    && install -D -m644 qrmi.h /usr/local/include/qrmi.h \
    && echo /usr/local/lib > /etc/ld.so.conf.d/qrmi.conf \
    && ldconfig \
    && gcc -shared -fPIC -O2 $(pkg-config --cflags lua) -I/usr/local/include \
           -o qrmi.so lua/lua_qrmi.c \
           -L/usr/local/lib -lqrmi $(pkg-config --libs lua) \
    && install -D -m755 qrmi.so /usr/lib64/lua/5.4/qrmi.so \
    && lua -e 'assert(require("qrmi")); print("qrmi Lua module OK")' \
    && cd / && rm -rf /tmp/qrmi "$HOME/.cargo/registry" "$HOME/.cargo/git"

# State of qrmi_hres.lua on slurmctld (state_dir default), owned by SlurmUser
RUN mkdir -p -m 0700 /var/spool/slurmctld/hres_qrmi \
    && chown -R slurm:slurm /var/spool/slurmctld

ARG OPENMPI_VERSION=4.1.8

RUN set -euxp pipefail \
    && wget -nv -O openmpi-${OPENMPI_VERSION}.tar.gz https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-${OPENMPI_VERSION}.tar.gz \
    && tar -xvf openmpi-${OPENMPI_VERSION}.tar.gz \
    && pushd openmpi-${OPENMPI_VERSION} \
    && ./configure --with-slurm --with-pmix="/usr/local/pmix-${OPENPMIx_VERSION}" --prefix="/usr/local/openmpi/${OPENMPI_VERSION}-pmix" \
    && make -j"$(nproc)" \
    && make install \
    && popd

ENV PATH="${PATH}:/usr/local/openmpi/${OPENMPI_VERSION}-pmix/bin" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/usr/local/openmpi/${OPENMPI_VERSION}-pmix/lib"

COPY slurm.conf /etc/slurm/slurm.conf
COPY slurmdbd.conf /etc/slurm/slurmdbd.conf
COPY cgroup.conf /etc/slurm/cgroup.conf
COPY qrmi_config.json.example /etc/slurm/qrmi_config.json.example
# HRES: resources.yaml.example (copy it to resources.yaml to enable), the hres/lua scripts and the
# TaskProlog. The scripts must be owned by root and writable only by root.
COPY --chown=root:root --chmod=0644 resources.yaml.example /etc/slurm/
COPY --chown=root:root --chmod=0644 hres_trace.lua qrmi_hres.lua /etc/slurm/
COPY --chown=root:root --chmod=0755 hres_qrmi_taskprolog.sh /etc/slurm/
# Per-user credentials: the directory tool (run as root) and the optional job_submit/lua check
COPY --chown=root:root --chmod=0755 qrmi_user_dir.sh /usr/local/sbin/qrmi_user_dir.sh
COPY --chown=root:root --chmod=0644 job_submit_qrmi.lua.example /etc/slurm/job_submit_qrmi.lua.example
RUN set -x \
    && chown slurm:slurm /etc/slurm/slurmdbd.conf \
    && chmod 600 /etc/slurm/slurmdbd.conf
RUN python3.12 -m venv ~/venv \
    && source ~/venv/bin/activate \
    && pip install --upgrade pip

ARG USERNAME=user
ARG GROUPNAME=user
ARG UID=1000
ARG GID=1000
RUN groupadd -g $GID $GROUPNAME && \
    useradd -m -s /bin/bash -u $UID -g $GID $USERNAME

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["slurmdbd"]
