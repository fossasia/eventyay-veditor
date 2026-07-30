FROM debian:stable-backports
COPY *.deb /root/
RUN apt-get update && apt-get -y --no-install-recommends install libmedia-convert-perl && apt-get -y --no-install-recommends install -t stable-backports libmedia-convert-perl && apt-get -y --no-install-recommends install /root/sreview-common*deb && apt-get clean
