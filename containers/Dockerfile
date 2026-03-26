FROM pangeo/pangeo-notebook:2025.05.22

USER root

RUN apt-get update --yes && \
    apt-get install --yes --no-install-recommends build-essential libproj-dev libgeos-dev libgdal-dev && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --chown=${NB_UID} environment.yml /home/jovyan/environment.yml

USER ${NB_UID}

RUN mamba env update -n notebook --file /home/jovyan/environment.yml && \
    mamba clean --all -y -f && \
    rm -rf ~/.cache/pip /home/jovyan/environment.yml
