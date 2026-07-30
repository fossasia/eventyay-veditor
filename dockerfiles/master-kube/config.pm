$state_actions = {
  'announcing' => 'run-kube announce <%== $talkid %>',
  'notify_final' => 'run-kube notify_final <%== $talkid %>',
  'cutting' => 'run-kube cut <%== $talkid %>',
  'generating_previews' => 'run-kube previews <%== $talkid %>',
  'notification' => 'run-kube notify <%== $talkid %>',
  'transcoding' => 'run-kube transcode <%== $talkid %>',
  'uploading' => 'run-kube upload <%== $talkid %>',
  'injecting' => 'run-kube inject-job <%== $talkid %>',
  'remove' => 'run-kube remove <%== $talkid %>',
};

1;
