ARG ci_registry_image
ARG ci_commit_ref_slug
FROM $ci_registry_image/master:$ci_commit_ref_slug
COPY run-kube /usr/local/bin/run-kube
COPY config.pm /etc/sreview/config.pm
RUN apt-get update && apt-get -y install curl libjson-perl libjson-xs-perl libyaml-libyaml-perl libdatetime-perl && curl -LO https://storage.googleapis.com/kubernetes-release/release/`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`/bin/linux/amd64/kubectl && apt-get --purge -y remove curl && apt-get --purge -y autoremove && chmod +x kubectl && mv kubectl /usr/local/bin/
