/* @licstart The following is the entire license notice for this
 * project, including all its JavaScript.
 *
 * SReview, a web-based video review and transcoding system.
 * Copyright (c) 2016-2017 Wouter Verhelst <w@uter.be>
 *
 * SReview is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation; either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public
 * License along with SReview. If not, see
 * <http://www.gnu.org/licenses/>.
 *
 * @licend The above is the entire license notice for this project,
 * including all its JavaScript.
 */
sreview_viddata.init = function() {
	this.current_length_adj = this.corrvals.length_adj;
	this.current_offset = this.corrvals.offset_start;
	this.lengths = {
		"pre": this.prelen,
		"main_initial": this.mainlen,
		"post": this.postlen
	};
	this.startpoints = {
		"pre": 0,
		"main": this.lengths.pre + this.corrvals.offset_start,
		"post": this.lengths.pre + this.corrvals.offset_start + this.lengths.main_initial + this.current_length_adj
	};
	this.newpoints = {
		"start": this.startpoints.main,
		"end": this.startpoints.post
	};
};

sreview_viddata.point_to_abs = function(which, where) {
	// which = which video (pre/main/post)
	// where = where the time value of the video should be (fractional seconds)
	return where + this.startpoints[which];
};

sreview_viddata.abs_to_offset = function(abs) {
	return abs - this.startpoints.main + this.current_offset;
};

sreview_viddata.abs_to_adj = function(abs) {
	let newlen = abs - this.newpoints.start;
	return newlen - this.lengths.main_initial;
};

sreview_viddata.set_point = function(which, what, where) {
	// which = which video (pre/main/post)
	// what = what point to set (start/end)
	// where = where the time value of the video should be (fractional seconds)
	this.newpoints[what] = this.point_to_abs(which, where);
};

sreview_viddata.get_start_offset = function() {
	return this.abs_to_offset(this.newpoints.start);
};

sreview_viddata.get_length_adjust = function() {
	return this.abs_to_adj(this.newpoints.end);
};

sreview_viddata.set_start_offset = function(off) {
	this.newpoints.start = this.startpoints.main + off;
};

sreview_viddata.set_length_adj = function(adj) {
	this.newpoints.end = this.newpoints.start + this.lengths.main_initial + adj;
};

sreview_viddata.init();
