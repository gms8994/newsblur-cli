#!/usr/bin/perl

use strict;
use Curses::UI;
use Text::Unidecode;
use Time::HiRes qw(gettimeofday);

my $cui = new Curses::UI(
	-color_support => 1,
);

$cui->leave_curses();

my $nb = Newsblur->new();
$nb->set_cui($cui);

my %subscriptions = $nb->get_subscriptions();
my %stories;
my @story_hashes = ();
my $last_sync_attempt = gettimeofday();

my $sub_list_width = 30;
my $story_list_height = 10;
my $selected_story = undef;

my ($mainwindow, $sub_list, $story_list, $story_container);

set_menu();
set_window();

$sub_list->focus();
$cui->mainloop();

sub attempt_sync {
	my ($message) = @_;
	$last_sync_attempt = gettimeofday();

	my $result = $nb->mark_as_read(\@story_hashes);
	@story_hashes = () if ($result);
	status("Counting is hard: $message", sub {
		$nb->refresh_feeds();
	});
}

sub draw_posts_window {
	my ($widget) = @_;

	my $feed_id = $widget->get();

	%stories = $nb->get_stories($feed_id);
	my $title = $subscriptions{$feed_id};
	$title =~ s/<\/?bold>//g;
	$story_list->title("Unread stories for " . $title);

	$story_container->text('');
	$story_container->title('');
	$story_container->draw();

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
				link_style => 'inline'
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

	if ($_does_not_have_converter) {
		$cui->status("This would be more readable if you installed the HTML::WikiConverter::Markdown perl module");
		sleep 5;
		$cui->nostatus;
	}

	$story_container->focus() if (length($content) > $max_chars);
}

sub set_menu {
	my @menu = ( { -label => 'File', -submenu => [ { -label => 'Exit      ^Q', -value => \&exit_dialog } ] } );
	my $menu = $cui->add( 'menu','Menubar', -menu => \@menu, -fg  => "blue" );

	$cui->set_binding( \&mark_unread, "u" );
	$cui->set_binding(sub {$menu->focus()}, "\cX");
	$cui->set_binding( \&exit_dialog , "\cQ" );
	$cui->set_binding( \&update_subscriptions, "\cR" );
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

	attempt_sync("Updating subscriptions");

	my %subscriptions = $nb->get_subscriptions();

	$sub_list->values([ keys(%subscriptions) ]);
	$sub_list->labels(\%subscriptions);
	$sub_list->draw();
}

sub set_window {
	$mainwindow = $cui->add( 'mainwindow', 'Window', -border => 1, -y    => 1, -bfg  => 'red' );

	$sub_list = $mainwindow->add(
		'subscription_list', 'Listbox',
		-width		  => $sub_list_width,
		-values		  => [ keys(%subscriptions) ],
		-labels		  => \%subscriptions,
		-border		  => 1,
		-vscrollbar	  => 1,
		-onchange	  => \&draw_posts_window
	);

	$story_list = $mainwindow->add(
		'story_list', 'Listbox',
		-x			  => $sub_list_width + 1,
		-height		  => $story_list_height,
		-border		  => 1,
		-vscrollbar	  => 1,
		-onchange	  => \&display_content
	);

	$story_container = $mainwindow->add(
		'story_container', 'TextViewer',
		-x			  => $sub_list_width + 1,
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

	$cui->status(
		-message => $status . " ...",
		-x => $sub_list_width,
		-y => 0
	);
	&$cb;
	$cui->nostatus();
}

sub sub_list {
	return $sub_list;
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
		$subscriptions{$feed_id} = '<bold>' . $result->{feeds}{$feed_id}{feed_title} . '</bold>';
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
		$result = decode_json($self->get('/reader/feed/' . $feed_id, { read_filter => 'unread' }));
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

	my $response = $ua->get($url);

	if (! $response->is_success()) {
		$self->error($response->decoded_content);
	}
	
	return $response->content();
}
sub post {
	my ($self, $endpoint, $parameters) = @_;

	my $ua = $self->{ua};
	my $url = URI->new($self->{_base_url});
	$url->path($endpoint);
	my $response = $ua->post($url, $parameters);

	if (! $response->is_success()) {
		$self->error($response->decoded_content);
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

	$self->{cui}->status($status . " ...");
	&$cb;
	$self->{cui}->nostatus();
}

sub nostatus {
	my ($self) = @_;

	$self->{cui}->nostatus();
}

sub error {
	my ($self, $content) = @_;

	$self->{cui}->error(
		-message => $content,
		-title   => 'Error Occurred! This will be logged to error.log',
	);

	open(my $fh, ">>", "error.log") || die "Couldn't write to error.log file: $!";
	print $fh $content;
	close($fh);

	$self->{cui}->exit_curses();
}
