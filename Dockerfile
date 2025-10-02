# Multi-stage build:
# 1) afni-builder: download AFNI assets, install AFNI deps, run AFNI installer to /opt/afni
# 2) fsl-builder: download FSL sources, install FSL deps, build wheel for fsl_mrs
# 3) freesurfer-builder: download Freesurfer .deb, extract payload and dependency list
# 4) runtime: combine all dependency lists, install packages, copy runtime files and pip-install wheel

ARG FREESURFER_VERSION=8.1.0
ARG FSL_VERSION=6.0.7.18
ARG FSL_REQ=requirements/requirements-fsl.txt
#####################
# AFNI builder stage
#####################
FROM ubuntu:22.04 AS afni-builder
ARG AFNI_REQ=requirements/requirements-afni.txt
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /tmp

COPY ${AFNI_REQ} requirements-afni.txt

# Install locales-all to provide pre-compiled locale data
RUN set -eux; \
    # Enable universe/multiverse so packages like firefox and some python helpers are available
    apt-get update && apt-get install -y --no-install-recommends software-properties-common dirmngr gnupg && \
    add-apt-repository -y universe || true; \
    add-apt-repository -y multiverse || true; \
    rm -rf /var/lib/apt/lists/*; \
    apt-get update && apt-get install -y locales-all && \
    # Set the desired locale and clean up
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set the locale environment variables
ENV LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en

# Install minimal tools, build dependency list, and install AFNI dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg2 dirmngr tcsh tar xz-utils sudo && \
    mkdir -p /deps && \
    cat requirements-afni.txt | sed 's/#.*//' | tr -d '\r' | awk '{$1=$1}; NF' | sort -u > /deps/afni-deps.txt && \
    xargs -r -a /deps/afni-deps.txt apt-get install -y --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Download AFNI binary bundle and helper script and run installer
RUN curl -LO https://afni.nimh.nih.gov/pub/dist/bin/misc/@update.afni.binaries && \
    curl -LO https://afni.nimh.nih.gov/pub/dist/tgz/linux_ubuntu_16_64.tgz && \
    tcsh @update.afni.binaries -local_package linux_ubuntu_16_64.tgz -do_extras -build_root /tmp/afni_install -bindir /opt/afni || true
# Cleanup AFNI payload to remove docs, tests and locales before it's copied to the final image
RUN set -eux; \
    if [ -d /opt/afni ]; then \
    find /opt/afni -type d \( -iname doc -o -iname docs -o -iname example* -o -iname demo* -o -iname test* -o -iname tests -o -iname share -o -iname man -o -iname locale -o -iname locales \) -prune -exec rm -rf {} + || true; \
    find /opt/afni -name '*.la' -delete || true; \
    find /opt/afni -name '__pycache__' -prune -exec rm -rf {} + || true; \
    fi

#####################
# FSL builder stage
#####################
FROM ubuntu:22.04 AS fsl-builder
ARG FSL_VERSION
ARG FSL_REQ=requirements/requirements-fsl.txt
ENV DEBIAN_FRONTEND=noninteractive
ENV FSLDIR=/opt/fsl
WORKDIR /tmp

# Copy the list of runtime/build deps for FSL and install a minimal build toolchain
COPY ${FSL_REQ} /tmp/requirements-fsl.txt

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    curl ca-certificates git git-lfs python3 python3-pip python3-venv python3-dev \
    build-essential pkg-config autoconf automake libtool bzip2 gnupg dirmngr \
    g++ make patch zlib1g-dev libpng-dev libgd-dev libopenblas-dev libboost-dev; \
    mkdir -p /deps; \
    sed 's/#.*//' /tmp/requirements-fsl.txt | tr -d '\r' | awk '{$1=$1}; NF' | sort -u > /deps/fsl-deps.txt; \
    xargs -r -a /deps/fsl-deps.txt apt-get install -y --no-install-recommends; \
    # Upgrade git-lfs to the latest official release to avoid runtime bugs in old versions
    curl -fsSL -o /tmp/git-lfs.deb https://github.com/git-lfs/git-lfs/releases/latest/download/git-lfs-linux-amd64.deb && \
    dpkg -i /tmp/git-lfs.deb && rm -f /tmp/git-lfs.deb; \
    rm -rf /var/lib/apt/lists/*

RUN wget https://fsl.fmrib.ox.ac.uk/fsldownloads/fslconda/releases/fslinstaller.py
RUN python3 ./fslinstaller.py -d /opt/fsl/ -c 13.0 --fslversion ${FSL_VERSION}

#####################
# Freesurfer builder stage
#####################
FROM ubuntu:22.04 AS freesurfer-builder
ARG FREESURFER_VERSION
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /tmp

# Install locales-all to provide pre-compiled locale data
RUN apt-get update && apt-get install -y locales-all && \
    # Set the desired locale and clean up
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set the locale environment variables
ENV LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en

# Install tools for extracting .deb and parsing control metadata
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates dpkg-dev tar xz-utils && rm -rf /var/lib/apt/lists/*

# Download freesurfer .deb and extract payload and build a dependency list
# COPY freesurfer_ubuntu22-8.1.0_amd64.deb .
RUN curl -LO https://surfer.nmr.mgh.harvard.edu/pub/dist/freesurfer/${FREESURFER_VERSION}/freesurfer_ubuntu22-${FREESURFER_VERSION}_amd64.deb

RUN set -eux; \
    dpkg-deb -x freesurfer_ubuntu22-${FREESURFER_VERSION}_amd64.deb /opt/freesurfer_payload && \
    dpkg-deb -e freesurfer_ubuntu22-${FREESURFER_VERSION}_amd64.deb /tmp/freesurfer_control || true && \
    mkdir -p /deps && \
    dpkg-deb -f freesurfer_ubuntu22-${FREESURFER_VERSION}_amd64.deb Depends 2>/dev/null | \
    awk 'BEGIN{RS=","} {gsub(/^[ \t]+|[ \t]+$/,"",$0); split($0,a,"|"); d=a[1]; gsub(/\s*\(.*\)/,"",d); if (d!="") print d}' > /deps/freesurfer-deps.txt || true
# Cleanup freesurfer payload to remove docs, tests and locales to shrink payload before copy
RUN set -eux; \
    if [ -d /opt/freesurfer_payload ]; then \
    find /opt/freesurfer_payload -type d \( -iname doc -o -iname docs -o -iname example* -o -iname demo* -o -iname test* -o -iname tests -o -iname share -o -iname man -o -iname locale -o -iname locales \) -prune -exec rm -rf {} + || true; \
    find /opt/freesurfer_payload -name '__pycache__' -prune -exec rm -rf {} + || true; \
    find /opt/freesurfer_payload -name '*.pyc' -delete || true; \
    fi
RUN curl -LO https://raw.githubusercontent.com/freesurfer/freesurfer/refs/heads/dev/recon_all_clinical/recon-all-clinical.sh && \
    chmod +x recon-all-clinical.sh && \
    cp recon-all-clinical.sh /opt/freesurfer_payload/usr/local/freesurfer/${FREESURFER_VERSION}/bin 
# copy recon-all-clinical wrapper
COPY recon-all-clinical /opt/freesurfer_payload/usr/local/freesurfer/${FREESURFER_VERSION}/bin/recon-all-clinical
#clean out some files that are not needed
RUN rm -rf /opt/freesurfer_payload/usr/local/freesurfer/${FREESURFER_VERSION}/subjects/* \
    /opt/freesurfer_payload/usr/local/freesurfer/${FREESURFER_VERSION}/trctrain/*

#####################
# Final runtime stage
#####################
FROM ubuntu:22.04 AS runtime
ARG FREESURFER_VERSION
ARG FSL_VERSION
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /workspace

# Copy dependency lists from builders and combine
COPY --from=afni-builder /deps/afni-deps.txt /tmp/afni-deps.txt
COPY --from=fsl-builder /deps/fsl-deps.txt /tmp/fsl-deps.txt
COPY --from=freesurfer-builder /deps/freesurfer-deps.txt /tmp/freesurfer-deps.txt
COPY requirements/requirements-extra.txt /tmp/extra-deps.txt

# Install locales-all to provide pre-compiled locale data
RUN apt-get update && apt-get install -y locales-all && \
    # Set the desired locale and clean up
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set the locale environment variables
ENV LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en

# create coder user early so we can use --chown on COPY and avoid an extra chown layer
RUN set -eux; \
    useradd -m coder && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /home/coder && \
    chown -R coder:coder /home/coder && \
    chmod 755 /home/coder

RUN set -eux; \
    cat /tmp/*.txt 2>/dev/null || true; \
    # Combine dependency lists from builders, strip comments/empty lines, and dedupe
    # Use awk to insert a blank line between each file when concatenating so a file that
    # lacks a trailing newline can't join its last token with the next file's first token
    awk 'FNR==1 && NR!=1{print ""} {print}' /tmp/*-deps.txt 2>/dev/null | sed 's/#.*//' | tr -d '\r' | awk '{$1=$1}; NF' | sort -u > /tmp/all-deps.txt || true; \
    if [ -s /tmp/all-deps.txt ]; then \
    echo "Installing all runtime apt packages from /tmp/all-deps.txt..."; \
    apt-get update && xargs -r -a /tmp/all-deps.txt apt-get install -y --no-install-recommends && rm -rf /var/lib/apt/lists/*; \
    else \
    echo "No combined apt deps to install"; \
    fi; \
    rm -f /tmp/*.txt

# Copy runtime artifacts from builders
COPY --from=afni-builder --chown=coder:coder /opt/afni /opt/afni
COPY --from=freesurfer-builder --chown=coder:coder /opt/freesurfer_payload/usr/local/freesurfer /opt/freesurfer
COPY --from=fsl-builder --chown=coder:coder /opt/fsl /opt/fsl

# use Zsh for my mac folks
RUN sh -c "$(curl -L https://github.com/deluan/zsh-in-docker/releases/download/v1.2.1/zsh-in-docker.sh)"

ENV FREESURFER_VERSION=${FREESURFER_VERSION}
ENV FREESURFER_HOME=/opt/freesurfer/${FREESURFER_VERSION}
ENV FSLDIR=/opt/fsl
ENV PATH='/opt/afni:${PATH}'

RUN echo 'export PATH=/opt/afni:$PATH' >> /etc/bash.bashrc
RUN echo 'export PATH=/opt/afni:$PATH' >> /etc/zsh/zshrc
RUN echo 'setenv PATH=/opt/afni:$PATH' >> /etc/csh.cshrc
RUN echo 'export FSLDIR=/opt/fsl' >> /etc/bash.bashrc
RUN echo 'export FSLDIR=/opt/fsl' >> /etc/zsh/zshrc
RUN echo 'setenv FSLDIR=/opt/fsl' >> /etc/csh.cshrc
RUN echo 'source ${FSLDIR}/etc/fslconf/fsl.sh' >> /etc/bash.bashrc
RUN echo 'source ${FSLDIR}/etc/fslconf/fsl.sh' >> /etc/zsh/zshrc
RUN echo 'source ${FSLDIR}/etc/fslconf/fsl.csh' >> /etc/csh.cshrc
RUN echo "export FREESURFER_VERSION=${FREESURFER_VERSION}" >> /etc/bash.bashrc
RUN echo "export FREESURFER_VERSION=${FREESURFER_VERSION}" >> /etc/zsh/zshrc
RUN echo "setenv FREESURFER_VERSION=${FREESURFER_VERSION}" >> /etc/csh.cshrc
RUN echo 'export FREESURFER_HOME=/opt/freesurfer/${FREESURFER_VERSION}' >> /etc/bash.bashrc
RUN echo 'export FREESURFER_HOME=/opt/freesurfer/${FREESURFER_VERSION}' >> /etc/zsh/zshrc
RUN echo 'setenv FREESURFER_HOME=/opt/freesurfer/${FREESURFER_VERSION}' >> /etc/csh.cshrc
RUN echo 'source ${FREESURFER_HOME}/SetUpFreeSurfer.sh' >> /etc/bash.bashrc
RUN echo 'source ${FREESURFER_HOME}/SetUpFreeSurfer.sh' >> /etc/zsh/zshrc
RUN echo 'source ${FREESURFER_HOME}/SetUpFreeSurfer.csh' >> /etc/csh.cshrc

USER coder
ENV HOME=/home/coder
CMD ["/bin/bash"]
