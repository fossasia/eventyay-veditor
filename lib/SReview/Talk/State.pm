package SReview::Talk::State;

use Class::Type::Enum values => [qw(
	waiting_for_files
	cutting
	generating_previews
	notification
	preview
	transcoding
	fixuping
	uploading
	publishing
	notify_final
	finalreview
	announcing
	transcribing
	syncing
	done
	injecting
	remove
	removing
	broken
	needs_work
	lost
	ignored
	uninteresting
)];


use overload '<=>' => 'cmp', '++' => "incr", '--' => "decr";

sub incr {
	if($_[0] eq "injecting") {
		${$_[0]} = $_[0]->sym_to_ord->{generating_previews};
	} else {
		++${$_[0]};
	}
}

sub decr {
	--${$_[0]};
}

1;
