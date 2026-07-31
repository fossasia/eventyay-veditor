FROM debian:unstable AS mcbuild
ARG MC_REPO=https://salsa.debian.org/wouter/media-convert
WORKDIR /tmp
RUN apt-get update && apt-get install -y --no-install-recommends git build-essential devscripts equivs
RUN git clone $MC_REPO media-convert
RUN cd media-convert && mk-build-deps -r -i -t "apt-get -y -o Debug::pkgProblemResolver=yes --no-install-recommends"
RUN cd media-convert && dpkg-buildpackage --build=binary -rfakeroot -uc -us -i -I.git

FROM debian:unstable
COPY --from=mcbuild /tmp/libmedia-convert-perl*deb /root/
RUN apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get --no-install-recommends install /root/libmedia-convert-perl*deb \
  bs1770gain \
  ffmpeg \
  fonts-font-awesome \
  inkscape \
  libclass-type-enum-perl \
  libcryptx-perl \
  libdatetime-format-pg-perl \
  libdatetime-format-iso8601-perl \
  libdatetime-perl \
  libextutils-depends-perl \
  libfile-which-perl \
  libjs-jquery \
  libjs-bootstrap4 \
  libjs-vue \
  libmojo-pg-perl \
  libmojolicious-perl \
  libmojolicious-plugin-openapi-perl \
  libmoose-perl \
  libnet-amazon-s3-perl \
  libtest-deep-perl \
  libtext-format-perl \
  libyaml-libyaml-perl \
  perl \
  postgresql-client \
  pwgen \
  python3-venv \
  -y
# torch without CUDA
RUN python3 -m venv /venv && /venv/bin/pip install torch --extra-index-url https://download.pytorch.org/whl/cpu && /venv/bin/pip install openai-whisper

RUN mkdir /etc/sreview

RUN mkdir -p /srv/sreview/web/public/video && ln -sf /srv/sreview/web/public/e /srv/sreview/web/public/video/e
WORKDIR /usr/share/sreview/

ADD /lib/ /usr/local/lib/site_perl/
ADD /scripts/sreview-config /usr/src/scripts/sreview-config

RUN cd /usr/src/scripts/ && ./sreview-config --action=update --set=adminpw=dev --set=adminuser=dev@dev.dev  --set=secret=INSECURE_DEV_SECRET --set=dbistring=dbi:Pg:dbname=sreviewdb\;host=db\;user=sreviewuser\;password=sreviewpassword --set=api_key=devkey --set=event=testevent --set=vid_prefix="" --set=preview_exten=mp4

CMD ./sreview-web daemon
EXPOSE 8080
