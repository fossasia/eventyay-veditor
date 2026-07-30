package SReview::Talk::Progress;

use Class::Type::Enum values => [qw(
	waiting
	scheduled
	running
	done
	failed
)];

use overload '<=>' => 'cmp', '++' => "incr", '--' => "decr";

sub incr {
	++${$_[0]};
}

sub decr {
	--${$_[0]};
}

1;
