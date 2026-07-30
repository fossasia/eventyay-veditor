ARG ci_registry_image
ARG ci_commit_ref_slug
FROM $ci_registry_image/common:$ci_commit_ref_slug
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install /root/sreview-web*deb wait-for-it && mkdir -p /var/run/sreview && chown sreview:sreview /var/run/sreview
ENV GIT_DESCRIBE @git_describe@
ENTRYPOINT ["/usr/bin/hypnotoad","-f","/usr/bin/sreview-web"]
EXPOSE 8080
