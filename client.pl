#!/usr/bin/perl

use strict;
use Curses::UI;
use Text::Unidecode;
use Time::HiRes qw(gettimeofday);

my $cui;

eval "use Curses::UI::POE;";

if (! $@) {
	$cui = new Curses::UI::POE(
		-color_support => 1,
	);
} else {
	$cui = new Curses::UI(
		-color_support => 1,
	);
}

$cui->leave_curses();

my $nb = Newsblur->new();
$nb->set_cui($cui);

my %subscriptions;
my %stories;
my @story_hashes = ();
my $last_sync_attempt = gettimeofday();

my $subscription_list_width = 30;
my $story_list_height = 10;
my $selected_story = undef;

my ($mainwindow, $subscription_list, $story_list, $story_container, $status_line);

set_menu();
set_window();

$nb->set_status_line($status_line);
$subscription_list->focus();
$cui->mainloop();

sub attempt_sync {
	my ($message) = @_;
	$last_sync_attempt = gettimeofday();

	status("Syncing read stories", sub {
		my $result = $nb->mark_as_read(\@story_hashes);
		@story_hashes = () if ($result);
	});
}

sub draw_posts_window {
	my $feed_id = $subscription_list->get();

	status("Getting stories remote");
	%stories = $nb->get_stories($feed_id);
	my $title = $subscriptions{$feed_id};
	$title =~ s/<\/?bold>//g;
	$story_list->title("Unread stories for " . $title);

	status("Updating the story container");
	$story_container->text('');
	$story_container->title('');
	$story_container->draw();

	status("Updating the stories");
	update_stories();
	$story_list->focus();
}

sub update_stories {
	my %labels = ();
	foreach my $story (keys %stories) {
		$labels{$story} = $stories{$story}{'title'};
	}
	
	$story_list->labels(\%labels);
	$story_list->values( [ keys(%stories) ] );
	$story_list->draw();
}

sub move_to_next_story {
	$story_list->focus();
	$story_list->option_next();
	$story_list->draw();
}

sub move_to_previous_story {
	$story_list->focus();
	$story_list->option_prev();
	$story_list->draw();
}

sub move_to_next_subscription {
	status("Moving to next subscription");
	$subscription_list->focus();
	$subscription_list->option_next();
	$subscription_list->set_selection($subscription_list->{-ypos});
	draw_posts_window();
}

sub move_to_previous_subscription {
	$subscription_list->focus();
	$subscription_list->option_prev();
	$subscription_list->draw();
	$subscription_list->set_selection($subscription_list->{-ypos});
	draw_posts_window();
}

sub mark_all_as_read {
	foreach my $story_id (@{$story_list->values()}) {
		$stories{$story_id}{title} =~ s/<\/?bold>//g;
		push(@story_hashes, $story_id);
	}
	update_stories();
	move_to_next_subscription();
	attempt_sync();
}

sub display_content {
	my ($widget) = @_;

	my $story_id = $widget->get();
	push(@story_hashes, $story_id);

	$stories{$story_id}{title} =~ s/<\/?bold>//g;
	update_stories();
	$selected_story = $story_id;
	$story_list->set_selection($story_id);

	my $content = unidecode($stories{$story_id}{content});
	eval "use HTML::WikiConverter;";

	my $_does_not_have_converter = $@;

	if (! $_does_not_have_converter) {
		eval "use HTML::WikiConverter::Markdown;";
		if (! $@) {
			my $wc = new HTML::WikiConverter(
				dialect => 'Markdown',
				header_style => 'setext',
				image_tag_fallback => 0
			);
			$content = $wc->html2wiki( $content );
		}
	}

	$story_list->height(scalar(keys(%stories)));
	$story_list->draw();
	$story_list->focus();

	my $max_chars = $story_container->height() * $story_container->width();
	$story_container->title($stories{$story_id}{link});
	$story_container->text($content);
	$story_container->cursor_to_home();
	$story_container->draw();
	$cui->schedule_event(\&attempt_sync);

	if ($_does_not_have_converter) {
		$cui->status("This would be more readable if you installed the HTML::WikiConverter::Markdown perl module");
		sleep 5;
		$cui->nostatus;
	}

	$story_container->focus();
}

sub set_menu {
	my @menu = ( { -label => 'File', -submenu => [ { -label => 'Exit      ^Q', -value => \&exit_dialog } ] } );
	my $menu = $cui->add( 'menu','Menubar', -menu => \@menu, -fg  => "blue" );

	$cui->set_binding( \&mark_unread, "u" );
	$cui->set_binding(sub {$menu->focus()}, "\cX");
	$cui->set_binding( \&exit_dialog , "\cQ" );
	$cui->set_binding( \&update_subscriptions, "\cR" );
	$cui->set_binding( \&move_to_next_story, "j" );
	$cui->set_binding( \&move_to_previous_story, "k" );
	$cui->set_binding( \&move_to_next_subscription, "J" );
	$cui->set_binding( \&move_to_previous_subscription, "K" );
	$cui->set_binding( \&mark_all_as_read, "A" );
	$cui->set_binding(sub {
		eval "use Browser::Open qw( open_browser );";

		if ($@) {
			$cui->status("You need to install the Browser::Open perl module to use this functionality");
		} else {
			my $url = $story_container->title();

			open_browser($url);
		};
	}, "o");
}

sub mark_unread {

	return unless defined $selected_story;

	if ($selected_story ~~ @story_hashes) {
		$cui->status($selected_story ~~ @story_hashes);
	}

}

sub update_subscriptions {
	status("Updating subscriptions", sub {
		%subscriptions = $nb->get_subscriptions();

		my $parent = $subscription_list->parentwindow();

		$subscription_list->values([ sort { $subscriptions{$a} <=> $subscriptions{$b} } keys(%subscriptions) ]);
		$subscription_list->labels(\%subscriptions);
		$subscription_list->{'-height'} = $parent->height() - 5;
		$subscription_list->draw();
	});
}

sub set_window {
	$cui->schedule_event(\&update_subscriptions);

	$mainwindow = $cui->add(
		'mainwindow', 'Window',
		-border => 1,
		-y      => 1,
		-bfg    => 'red'
	);

	my $left_pane = $mainwindow->add(
		'left_pane', 'Container',
		-width		  => $subscription_list_width
	);

	$subscription_list = $left_pane->add(
		'subscription_list', 'Listbox',
		-parent		  => 'left_pane',
		-width		  => $subscription_list_width,
		-height		  => $mainwindow->height() - 6,
		-values		  => [ sort { $subscriptions{$a} <=> $subscriptions{$b} } keys(%subscriptions) ],
		-labels		  => \%subscriptions,
		-border		  => 1,
		-vscrollbar	  => 1,
		-onchange	  => \&draw_posts_window,
	);

	$status_line = $left_pane->add( 
		'status_line', 'TextViewer',
		-parent		  => 'left_pane',
		-text		  => "Hello, world!",
		-y			  => $mainwindow->height() - 6,
		-width		  => $subscription_list_width,
		-border		  => 1,
		-vscrollbar	  => 1,
	);

	my $right_pane = $mainwindow->add(
		'right_pane', 'Container',
		-x			  => $subscription_list_width + 1
	);

	$story_list = $right_pane->add(
		'story_list', 'Listbox',
		-height		  => $story_list_height,
		-border		  => 1,
		-vscrollbar	  => 1,
		-onchange	  => \&display_content
	);

	$story_container = $right_pane->add(
		'story_container', 'TextViewer',
		-y			  => $story_list_height,
		-border		  => 1,
		-wrapping	  => 1,
		-singleline	  => 0,
		-vscrollbar	  => 1,
		-showoverflow => 0
	);
}

sub status {
	my ($status, $cb) = @_;

	$status_line->text($status);
	if (defined($cb)) {
		&$cb;
		$status_line->text($status . " done");
	}
}

sub subscription_list {
	return $subscription_list;
}

sub exit_dialog {
	my $return = $cui->dialog(
		-message   => "Do you really want to quit?",
		-title     => "Are you sure???", 
		-buttons   => ['yes', 'no'],
	);

	exit(0) if $return;
}

package Newsblur;

use utf8;
use JSON;
use LWP::UserAgent;
use Text::Unidecode;
use Time::HiRes qw/gettimeofday tv_interval/;
use URI;
use URI::QueryParam;

sub new {
	my ($class_name) = @_;
	my ($self) = {};

	bless ($self, $class_name);
	$self->{'_created'} = 1;
	$self->{'_base_url'} = 'https://www.newsblur.com';

	my $ua = LWP::UserAgent->new();
	$ua->cookie_jar({ file => "$ENV{HOME}/.cookies.txt", autosave => 1 });
	$ua->timeout(30);
	$ua->env_proxy;
	$self->{'ua'} = $ua;

	return $self;
}

sub set_cui {
	my ($self, $cui) = @_;

	$self->{'cui'} = $cui;

	return $self;
}

sub set_status_line {
	my ($self, $status_line) = @_;

	$self->{'status_line'} = $status_line;

	return $self;
}

sub get_subscriptions {
	my ($self) = @_;

	if (! $self->is_logged_in()) {
		$self->login();
	}

	my $result;
	$self->status("Getting feeds", sub {
		$result = decode_json($self->get('/reader/feeds', { }));
	});

	my %subscriptions = ();
	foreach my $feed_id (keys %{$result->{feeds}}) {
		next unless
			$result->{feeds}{$feed_id}{nt} > 0 # neutral intelligence
			|| $result->{feeds}{$feed_id}{ps} > 0; # positive intelligence

		$subscriptions{$feed_id} = sprintf(
			'<bold>%s</bold> (%d)',
			$result->{feeds}{$feed_id}{feed_title},
			$result->{feeds}{$feed_id}{nt} + $result->{feeds}{$feed_id}{ps}
		);
	}
	
	return %subscriptions;
}

sub mark_as_read {
	my ($self, $hashes) = @_;

	my $result = decode_json($self->post('/reader/mark_story_hashes_as_read', { story_hash => $hashes }));

	return 1 if ($result->{result} eq 'ok');
	return 0;
}

sub refresh_feeds {
	my ($self, $hashes) = @_;

	my $result = decode_json($self->get('/reader/refresh_feeds'));

	return 1 if ($result->{result} eq 'ok');
	return 0;
}

sub get_stories {
	my ($self, $feed_id) = @_;

	return unless $feed_id;

	if (! $self->is_logged_in()) {
		$self->login();
	}

	my $result;
	$self->status("Getting stories for feed", sub {

		my $page_stories;

		for(my $page = 1; $page <= 3; $page++) {
			$page_stories = decode_json($self->get('/reader/feed/' . $feed_id, { read_filter => 'unread', 'page' => $page }));

			# if there's less than 5 items, we don't need to loop anymore
			if (scalar(@{$page_stories->{stories}}) < 5) {
				$page = 4;
			}

			if ($result == undef) {
				$result = $page_stories;
			} else {
				foreach my $story (@{$page_stories->{stories}}) {
					push(@{$result->{stories}}, $story);
				}
			}
		}
	});

	my %stories = ();
	foreach my $story (@{$result->{stories}}) {
		$stories{$story->{story_hash}} = {
			title => '<bold>' . $story->{story_title} . '</bold>',
			content => $story->{story_content},
			link => $story->{story_permalink}
		};
	}
	
	return %stories;
}
sub get {
	my ($self, $endpoint, $parameters) = @_;

	my $ua = $self->{ua};
	my $url = URI->new($self->{_base_url});
	$url->path($endpoint);
	$url->query_form_hash($parameters) if $parameters;

	my $start = [gettimeofday];
	$self->log("GET $url ...");
	my $response = $ua->get($url);
	$self->log(" (" . tv_interval ( $start, [gettimeofday]) . ")", 1);

	if (! $response->is_success()) {
		$self->error($response->decoded_content, $response->status_line);
	}
	
	return $response->content();
}
sub post {
	my ($self, $endpoint, $parameters) = @_;

	my $ua = $self->{ua};
	my $url = URI->new($self->{_base_url});
	$url->path($endpoint);

	my $start = [gettimeofday];
	$self->log("POST $url ...");
	my $response = $ua->post($url, $parameters);
	$self->log(" (" . tv_interval ( $start, [gettimeofday]) . ")", 1);

	if (! $response->is_success()) {
		$self->error($response->decoded_content, $response->status_line);
	}
	
	return $response->content();
}

sub is_logged_in {
	my ($self) = @_;

	if (! $self->{_logged_in}) {
		my @cookies = grep { /newsblur.com/ } split /\n/, $self->{ua}->cookie_jar()->as_string;

		if (scalar(@cookies) == 1) {
			$self->{_logged_in} = 1;
		}
	}

	return $self->{_logged_in} if ($self->{_logged_in});
	return 0;
}

sub login {
	my ($self) = @_;

	my $username = $self->{cui}->question("What is your Newsblur.com username?");

	## This here is the crazyness that has to happen to get a password based question box with Curses::UI
    my $id = "__window_Dialog::Question";
    my $dialog = $self->{cui}->add($id, 'Dialog::Question', -question => "What is your newsblur.com password?", -password => '*');
	my $te = $dialog->getobj('answer');
	$te->{-password} = '*';
    $dialog->modalfocus;
    my $password = $dialog->get;
    $self->{cui}->delete($id);
    $self->{cui}->root->focus(undef, 1);

	my $result;
	$self->status("Attempting to log in", sub {
		$result = decode_json($self->post('/api/login', { username => $username, password => $password }));
	});

	if ($result->{errors}) {
		$self->error($result->{errors});
	}

	$self->status("Logged in successfully!", sub {
		$self->{_logged_in} = 1;
	});
}

sub status {
	my ($self, $status, $cb) = @_;

	if (! defined($self->{status_line})) {
		$self->{cui}->status($status);
	} else {
		$self->{status_line}->text($status);
	}
	&$cb;
	if (! defined($self->{status_line})) {
		$self->{cui}->nostatus;
	}
}

sub nostatus {
	my ($self) = @_;

	$self->{cui}->nostatus();
}

sub log {
	my ($self, $message, $end_with_newline) = @_;

	open(my $fh, ">>", "messages.log") || die "Couldn't write to messages.log file: $!";
	print $fh $message;
	if ($end_with_newline == 1) {
		print $fh "\n";
	}
	close($fh);
}

sub error {
	my ($self, $content, $status_line) = @_;

	$self->{cui}->error(
		-message => $content,
		-title   => 'Error Occurred! This will be logged to error.log',
	);

	open(my $fh, ">>", "error.log") || die "Couldn't write to error.log file: $!";
	print $fh $content;
	print $fh $status_line;
	close($fh);

	$self->{cui}->exit_curses();
}
