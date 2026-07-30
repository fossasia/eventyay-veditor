Vue.component("talk-preview", {
  template: `
    <div class="col-md-4 text-center">
      <video v-if="isVideo" class="img-fluid" controls="controls" playsinline="playsinline">
        <source v-bind:src="url" v-bind:type="contentType" />
      </video>
      <img v-if="!isVideo" class="img-fluid" v-bind:src="url">
      <button class="btn btn-primary" v-on:click="setForce"><i class="fa fa-regular fa-rotate-right"></i></button>
    </div>`,
  props: ["talk", "which"],
  computed: {
    url: function() {
      return "/api/v1/nonce/" + this.talk.nonce + "/" + this.which + "?force=" + this.force;
    },
  },
  methods: {
    setForce: function() {
      this.force = Date.now();
    },
    refreshContentType: function() {
      fetch(this.url, { method: "HEAD" })
      .then((response) => {
        const ct = response.headers.get("content-type");
        if (ct) {
          this.contentType = ct;
          this.isVideo = ct.startsWith("video/");
        } else {
          this.contentType = null;
          this.isVideo = false;
        }
      })
      .catch(() => {
        this.contentType = null;
        this.isVideo = false;
      });
    }
  },
  data: function() {
    return {
      force: false,
      contentType: null,
      isVideo: false,
    }
  },
  watch: {
    force: function() {
      this.refreshContentType();
    },
  },
  mounted: function() {
    this.refreshContentType();
  },
})

const load_event = function() {
  fetch("/api/v1/event/" + app.event + "/overview")
  .then(response => response.json())
  .then((data) => {app.rows = data.filter((row) => row.state !== "ignored")})
  .catch(error => console.error(error));
};

var app = new Vue({
  el: '#preview',
  data: {
    title: "",
    rows: [],
    events: [],
    event: undefined,
  },
  methods: {
    reloadEvent: load_event,
  },
  watch: {
    event: load_event,
  },
  created: function() {
    fetch("/api/v1/config")
    .then(response => response.json())
    .then(data => {this.event = data.event})
    .catch(error => console.error(error));
    fetch("/api/v1/event/list")
    .then(response => response.json())
    .then(data => {this.events = data})
    .catch(error => console.error(error));
  },
});
