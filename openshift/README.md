The `sreview.yaml` file in this directory contains an OpenShift (v3)
template that uses a set of BuildConfig etc objects to rebuild the
SReview containers inside OpenShift.

It requires administrator access to create the Role and the RoleBinding
so that the sreview-master deployment can start encoder jobs.
Everything else should work fine without those.

Tested on minishift, not in production (yet?)
