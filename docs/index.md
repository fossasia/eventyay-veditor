# SReview documentation

Welcome to SReview, a video review and transcoding system.

Please note that any changes you make while reviewing your talk video
will only be visible after you have submitted it for re-cutting.

There are two main ways to run SReview.  Anonymous mode keeps an
overview list of talks to be reviewed, so anyone with access to the list
can review.  Notification mode directly informs people by email of the
URL of a specific video to be reviewed.

## Reviewing

If you received an email stating that your talk is ready for review, but
the review page claims it is *not* ready, someone else may have already
done some reviewing on it. Check the Cc field on the initial
notification email for other recipients. Additionally, people with
administration logon credentials may review any talk, even if they
didn’t get the notification email.

### The web form

The review form shows three video elements; one large video, and two
small ones. The large video should contain *just* the talk that this
video should contain, plus possibly an introduction at the start and the
questions at the end, but no more and no less than that.

The two smaller video elements above the large video element contain
*context* video; the twenty minutes before and the twenty minutes after
the large video element. These may be helpful should the main video
start too late or stop too soon, and are re-cut whenever the main video
is re-cut (so the end of the pre video should always be *just* before
the start of the main video).

Below the three video elements is a web form where you can decide what
to do. Read on.

If you review the recording, and all is well, just select the option
labeled “This preview looks OK, please transcode it at high quality and
release it” in the webform and submit it. Everything else will now
happen automatically. You’re done!

If the start and end points of the video are incorrect, locate the
correct points in either the main video or the two smaller context
videos.  Using the pause button is helpful here, but not obligatory.
Once you've found them, set them with "Take start point" and "Take end
point".  This will automatically set the correct values in the "Common
fixes" section.  Then, press "OK" to submit the video for re-cutting.

If the video and audio are out of sync, and you feel confident adjusting
it yourself, fill in an estimated value in the "audio offset" field
under "Common fixes" and send the video for re-cutting. You will be able
to check the adjustment after the video has been re-cut and you have a
new preview.

If the audio is of poor quality, try changing the audio channel under
"Common fixes".

If you don't feel confident adjusting the audio offset or channel
yourself, select "This preview has the following issues not covered by
the above" under "Other brokenness", and describe the problem in the
text box there.

Once you’ve made all the changes you think are needed, hit the “OK”
button at the bottom of the page. Your talk will then be re-cut, after
which it will be available for review again. If SReview is running in
notification mode, you’ll get another notification email. You can check
the new cut, make any more changes as needed, and re-submit the talk.
Once your talk is just as you want it, select "This preview looks OK,
please transcode it at high quality ad release it" and press "OK".

If you see a problem not covered by "Common Fixes", please select the
"Other brokenness" option, and explain the issue in the text area below
that. Once you’ve submitted the form, your talk will now be placed in
the “broken” state. If you change your mind, you can always choose the
‘Do not make changes, do not notify video team; set the state back to
“preview”’ option. You can then go back to reviewing, as usual.

Thanks for reviewing!

## Further documentation

There is a document about the [components](components) of SReview, which
explains how the system works. If you want to install, read the
[installation](installation) document.
