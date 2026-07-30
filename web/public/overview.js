"use strict";

const unique_filter = function(value, index, self) {
  return self.indexOf(value) === index;
}

const validate_timestamp = function(string) {
  if (! string) {
    return false;
  }
  if (string.length < 16) {
    return false;
  }
  const obj = new Date(string);
  if (obj.toString() == 'Invalid Date') {
    return false;
  }
  if (obj.getTime() == 0) {
    return false;
  }
  return true;
}

// Replaced when we know the API key
var auth_fetch = fetch;

const load_event = function() {
  fetch("/api/v1/event/" + vm.event + "/overview")
  .then(response => response.json())
  .then(function (data) {
    vm.talks = data.map(event => {
      event.starttime_date = event.starttime.split("T")[0];
      event.starttime_time = event.starttime.split("T")[1];
      event.endtime_date = event.endtime.split("T")[0];
      event.endtime_time = event.endtime.split("T")[1];
      if (event.starttime_date == event.endtime_date) {
        event.dates = event.starttime_date;
      } else {
        event.dates = event.starttime_date + '-' + event.endtime_date;
      }
      return event;
    });
    vm.days = data.map(event => event.starttime_date)
      .filter(unique_filter)
      .sort();
    vm.rooms = data.map(event => event.room)
      .filter(unique_filter)
      .sort();
    vm.tracks = data.map(event => event.track)
      .filter(unique_filter)
      .sort();
    vm.states = data.map(event => event.state)
      .filter(unique_filter)
      .sort();
    vm.progresses = data.map(event => event.progress)
      .filter(unique_filter)
      .sort();
  })
  .catch(error => console.error(error));
};

const search_text = function(search_terms, talk) {
  const needle = search_terms.toLowerCase();
  for (const field of ['name', 'speakers']) {
    const value = talk[field];
    if (needle === undefined) {
      continue;
    }
    if (value.toLowerCase().includes(needle)) {
      return true;
    }
  }
  return false;
}

const filter_talks = function() {
  vm.rows = vm.talks.filter(talk => {
    if (vm.search && ! search_text(vm.search, talk)) {
      return false;
    }
    if (! vm.selected_dates.includes(talk.starttime_date)) {
      return false;
    }
    if (! vm.selected_rooms.includes(talk.room)) {
      return false;
    }
    if (vm.tracks && ! vm.selected_tracks.includes(talk.track)) {
      return false;
    }
    if (! vm.selected_states.includes(talk.state)) {
      return false;
    }
    if (! vm.selected_progresses.includes(talk.progress)) {
      return false;
    }
    return true;
  });
}

const filter_component = Vue.component('navbar-filter', {
  template: '#navbar-filter-template',
  props: [
    'name',
    'options',
  ],
  data: () => {
    return {
      id: 'no-id-yet',
      checkboxes: [],
      selected_all: true,
      selected_none: false,
    };
  },
  watch: {
    checkboxes: {
      handler: function(val) {
        const selected = val.filter(option => option.checked)
          .map(option => option.value);
        this.$emit('update:selected', selected);
        this.selected_all = val.filter(option => !option.checked).length === 0;
        this.selected_none = val.filter(option => option.checked).length === 0;
      },
      deep: true,
    },
    options: function(val) {
      this.checkboxes = val.map((option, index) => ({
        id: this.id + '-' + index,
        checked: true,
        value: option,
        name: option || 'None',
      }));
    },
  },
  methods: {
    select_all: function() {
      this.checkboxes.map(option => option.checked = true);
    },
    select_none: function() {
      this.checkboxes.map(option => option.checked = false);
    },
  },
  mounted: function() {
    this.id = 'navbar-filter-' + this._uid;
  },
});

const blank_talk_edit_modal_data = () => ({
  active_stream: null,
  apologynote: null,
  description: null,
  endtime: null,
  flags: {},
  id: null,
  perc: null,
  postlen: null,
  prelen: null,
  progress: 'waiting',
  reviewer: null,
  room: null,
  slug: null,
  speakers: [],
  speaker_search: '',
  speaker_search_results: [],
  starttime: null,
  state: 'waiting_for_files',
  subtitle: null,
  title: null,
  track: null,
  upstreamid: null,
  valid_starttime: null,
  valid_endtime: null,
  valid: false,
});

const validate_edit_talk = function() {
  this.valid = this.title && this.valid_starttime && this.valid_endtime
               && this.room;
}

const talk_edit_modal_component = Vue.component('talk-edit-modal', {
  template: '#talk-edit-modal-template',
  props: [
    'event',
    'nonce',
    'new_talk',
  ],
  data: () => {
    return Object.assign({
      tracks: [],
      rooms: [],
      states: [],
      progresses: [],
    }, blank_talk_edit_modal_data());
  },
  watch: {
    id: function(val) {
      if (val == null) {
        return;
      }
      auth_fetch("/api/v1/event/" + vm.event + "/talk/" + val + "/speakers")
      .then(response => response.json())
      .then(data => {this.speakers = data})
      .catch(error => console.error(error));
    },
    nonce: function(val) {
      Object.assign(this, blank_talk_edit_modal_data());
      if (val === undefined) {
        return this.update_visibility();
      }
      fetch("/api/v1/nonce/" + val + "/talk")
      .then(response => response.json())
      .then(data => {
        data.track = data.track ? data.track : '';
        Object.assign(this, data);
        this.update_visibility();
      })
      .catch(error => console.error(error));
    },
    new_talk: function(val) {
      Object.assign(this, blank_talk_edit_modal_data());
      this.update_visibility();
    },
    speaker_search: function(val) {
      if (!val || val.length < 3) {
        this.speaker_search_results = [];
        return;
      }
      auth_fetch("/api/v1/speaker/search/" + encodeURIComponent(val))
      .then(response => response.json())
      .then(data => data.filter(speaker => speaker.event == vm.event))
      .then(data => this.speaker_search_results = data)
      .catch(error => console.error(error));
    },
    starttime: function(val) {
      this.valid_starttime = validate_timestamp(val);
    },
    endtime: function(val) {
      this.valid_endtime = validate_timestamp(val);
    },
    room: validate_edit_talk,
    title: validate_edit_talk,
    valid_starttime: validate_edit_talk,
    valid_endtime: validate_edit_talk,
  },
  methods: {
    dismiss_modal: function() {
      this.$emit('dismissed');
    },
    add_speaker: function(speaker) {
      this.speakers.push(speaker);
    },
    remove_speaker: function(speaker_id) {
      this.speakers = this.speakers.filter(speaker => speaker.id != speaker_id);
    },
    save: function() {
      this.starttime = new Date(this.starttime).toISOString();
      this.endtime = new Date(this.endtime).toISOString();
      const body = [
        'title', 'subtitle', 'description', 'apologynote', 'starttime', 'endtime', 'track',
        'room', 'state', 'progress', 'active_stream'
      ].reduce((obj, attr) => {
          obj[attr] = this[attr];
          return obj;
      }, {});
      if (body.track === '') {
        body.track = null;
      }
      const url = "/api/v1/event/" + vm.event + "/talk"
            + (this.new_talk ? "" : "/" + this.id);
      const method = this.new_talk ? "POST" : "PATCH";
      auth_fetch(url, {
        method: method,
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
      })
      .then(response => response.json())
      .then(data => {
        if (data.errors) {
          console.error(data.errors.map(error => error.message));
          return;
        }
        auth_fetch(
          "/api/v1/event/" + vm.event + "/talk/" + data.id + "/speakers", {
          method: "PUT",
          headers: {
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(this.speakers.map(speaker => speaker.id)),
        })
        .then(response => response.json())
        .then(this.$emit('saved'))
        .catch(error => console.error(error));
      })
      .catch(error => console.error(error));
    },
    update_visibility: function() {
      const visible = !!(this.nonce || this.new_talk);
      if (visible != this.visible) {
        const modal = $('.modal');
        if (visible) {
          modal.show();
          $('.modal .modal-body').scrollTop(0);
        } else {
          modal.hide();
        }
      }
      this.visible = visible;
    },
  },
  mounted: function() {
    this.progresses = [
      'waiting',
      'scheduled',
      'running',
      'done',
      'failed',
    ];

    if (auth_fetch != fetch) {
      auth_fetch("/api/v1/track/list")
      .then(response => response.json())
      .then(data => {this.tracks = data})
      .catch(error => console.error(error));
    };

    fetch("/api/v1/room/list")
    .then(response => response.json())
    .then(data => {this.rooms = data})
    .catch(error => console.error(error));

    fetch("/api/v1/config/legend")
    .then(response => response.json())
    .then(data => {this.states = data.map(expl => expl.name)})
    .catch(error => console.error(error));
  },
});

const vm = new Vue({
  el: '#overview',
  data: {
    admin_key: undefined,
    title: "",
    talks: [],  // unfiltered
    search: "",
    selected_dates: [],
    selected_rooms: [],
    selected_tracks: [],
    selected_states: [],
    selected_progresses: [],
    rows: [],   // filtered
    events: [],
    days: [],
    rooms: [],
    tracks: [],
    states: [],
    progresses: [],
    event: undefined,
    state_descriptions: {},
    edit_talk_modal_nonce: undefined,
    new_talk_modal: false,
  },
  methods: {
    reloadEvent: function() {
      load_event(this.event);
    },
    dismiss_talk_edit_modal: function() {
      this.edit_talk_modal_nonce = undefined;
      this.new_talk_modal = false;
    },
    talk_edit_complete: function() {
      this.reloadEvent();
      this.dismiss_talk_edit_modal();
    },
  },
  watch: {
    event: load_event,
    search: filter_talks,
    talks: filter_talks,
    selected_dates: filter_talks,
    selected_rooms: filter_talks,
    selected_tracks: filter_talks,
    selected_states: filter_talks,
    selected_progresses: filter_talks,
  },
  created: function() {
    const admin_cookie = document.cookie.split(';')
      .find(cookie => cookie.trim().startsWith('sreview_api_key='));
    if (admin_cookie) {
      const admin_key = admin_cookie.split('=')[1].trim();
      this.admin_key = admin_key;
      auth_fetch = function(resource, options) {
        if (options === undefined) {
          options = {};
        }
        if (options.headers === undefined) {
          options.headers = {};
        }
        options.headers['X-SReview-Key'] = admin_key;
        return fetch(resource, options)
        .then(response => {
          if(response.status == 401) {
            vm.admin_key = null;
            auth_fetch = fetch;
            document.cookie = 'sreview_api_key=; expires=Thu, 01 Jan 1970 00:00:00 GMT';
            throw Error("Not Authenticated");
          }
          return response;
        });
      }
    }
    fetch("/api/v1/config")
    .then(response => response.json())
    .then(data => {this.event = data.event})
    .catch(error => console.error(error));
    fetch("/api/v1/event/list")
    .then(response => response.json())
    .then(data => {this.events = data})
    .catch(error => console.error(error));
    fetch("/api/v1/config/legend/")
    .then(response => response.json())
    .then((data) => {
      vm.state_descriptions = data.reduce((obj, expl) => {
        obj[expl.name] = expl.expl;
        return obj;
      }, {});
    })
    .catch(error => console.error(error));
  }
});
