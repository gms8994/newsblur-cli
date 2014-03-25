#!/usr/bin/perl

use strict;
use Curses::UI;
use Data::Dumper;
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

my ($mainwindow, $sub_list, $story_list, $story_container);

set_menu();
set_window();

$sub_list->focus();
$cui->add_callback('story_container', sub {
	my ($widget) = @_;

	if (((gettimeofday() - 10) > $last_sync_attempt)
		&& (scalar(@story_hashes) > 0)) {
		$last_sync_attempt = gettimeofday();

		my $result = $nb->mark_as_read(\@story_hashes);
		@story_hashes = () if ($result);
	}
});
$cui->mainloop();

sub draw_posts_window() {
	my ($widget) = @_;

	my $feed_id = $widget->get();

	%stories = $nb->get_stories($feed_id);
	$story_list->title("Unread stories for " . $subscriptions{$feed_id});

	my %labels = ();
	foreach my $story (keys %stories) {
		$labels{$story} = $stories{$story}{'title'};
	}
	
	$story_container->text('');
	$story_container->title('');
	$story_container->draw();

	$story_list->labels(\%labels);
	$story_list->values( [ keys(%stories) ] );
	$story_list->draw();
	$story_list->focus();
}

sub display_content() {
	my ($widget) = @_;

	my $story_id = $widget->get();
	push(@story_hashes, $story_id);

	my $content = $stories{$story_id}{content};
	eval {
		use HTML::Entities;
		use HTML::Restrict;

		my $hs = HTML::Restrict->new(
			trim			=> 0,
			replace_image	=> sub {
				my ($tagname, $attr, $text) = @_; # from HTML::Parser
				return qq{ (IMAGE: $attr->{alt} )};
			},
			rules			=> {
				p   => [],
			}
		);
		$content = $hs->process( $stories{$story_id}{content} );
		$content =~ s/<p>//g;
		$content =~ s/<\/p>/\n\n/g;
		$content =~ s/(\n\n)+/\n\n/g;
		$content = decode_entities($content);
	};

	$story_list->height(scalar(keys(%stories)));
	$story_list->draw();
	$story_list->focus();

	my $max_chars = $story_container->height() * $story_container->width();
	$story_container->title($stories{$story_id}{link});
	$story_container->text($content);
	$story_container->cursor_to_home();
	$story_container->draw();

	$story_container->focus() if (length($content) > $max_chars);
}

sub set_menu() {
	my @menu = ( { -label => 'File', -submenu => [ { -label => 'Exit      ^Q', -value => \&exit_dialog } ] } );
	my $menu = $cui->add( 'menu','Menubar', -menu => \@menu, -fg  => "blue" );

	$cui->set_binding(sub {$menu->focus()}, "\cX");
	$cui->set_binding( \&exit_dialog , "\cQ");
}

sub set_window() {
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

sub status() {
	my ($status) = @_;

	$cui->status($status . " ...");
}

sub exit_dialog() {
	my $return = $cui->dialog(
		-message   => "Do you really want to quit?",
		-title     => "Are you sure???", 
		-buttons   => ['yes', 'no'],
	);

	exit(0) if $return;
}

package Newsblur;

use Data::Dumper;
use JSON;
use LWP::UserAgent;
use URI;
use URI::QueryParam;

sub new() {
	my ($class_name) = @_;
	my ($self) = {};

	bless ($self, $class_name);
	$self->{'_created'} = 1;
	$self->{'_base_url'} = 'https://www.newsblur.com';

	my $ua = LWP::UserAgent->new();
	$ua->cookie_jar({ file => "$ENV{HOME}/.cookies.txt" });
	$ua->timeout(10);
	$ua->env_proxy;
	$self->{'ua'} = $ua;

	return $self;
}

sub set_cui() {
	my ($self, $cui) = @_;

	$self->{'cui'} = $cui;

	return $self;
}

sub get_subscriptions() {
	my ($self) = @_;

	if (! $self->is_logged_in()) {
		$self->login();
	}

	$self->status("Getting feeds");
	my $result = decode_json($self->get('/reader/feeds', { }));

	my %subscriptions = ();
	foreach my $feed_id (keys %{$result->{feeds}}) {
		next unless $result->{feeds}{$feed_id}{nt} > 0; # new topics maybe?
		$subscriptions{$feed_id} = $result->{feeds}{$feed_id}{feed_title};
	}
	
	return %subscriptions;
}

sub mark_as_read() {
	my ($self, $hashes) = @_;

	my $result = decode_json($self->post('/reader/mark_story_hashes_as_read', { story_hash => $hashes }));

	return 1 if ($result->{result} eq 'ok');
	return 0;
}

sub get_stories() {
	my ($self, $feed_id) = @_;

	return unless $feed_id;

	if (! $self->is_logged_in()) {
		$self->login();
	}

	$self->status("Getting stories for feed");
	my $result = decode_json($self->get('/reader/feed/' . $feed_id, { read_filter => 'unread' }));

	my %stories = ();
	foreach my $story (@{$result->{stories}}) {
		$stories{$story->{story_hash}} = {
			title => $story->{story_title},
			content => $story->{story_content},
			link => $story->{story_permalink}
		};
	}
	
	return %stories;
}
sub get() {
	my ($self, $endpoint, $parameters) = @_;

	my $ua = $self->{ua};
	my $url = URI->new($self->{_base_url});
	$url->path($endpoint);
	$url->query_form_hash($parameters);

	my $response = $ua->get($url);

	if (! $response->is_success()) {
		$self->error($response->decoded_content);
	}
	
	return $response->content();
}
sub post() {
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

sub is_logged_in() {
	my ($self) = @_;

	return $self->{_logged_in} if ($self->{_logged_in});
	return 0;
}

sub login() {
	my ($self) = @_;

	my $username = $self->{cui}->question("What is your Newsblur.com username?");
	my $password = $self->{cui}->question("What is your Newsblur.com password?");

	$self->status("Attempting to log in");
	my $result = decode_json($self->post('/api/login', { username => $username, password => $password }));

	if ($result->{errors}) {
		$self->error($result->{errors});
	}

	$self->status("Logged in successfully!");
	$self->{_logged_in} = 1;
}

sub status() {
	my ($self, $status) = @_;

	$self->{cui}->status($status . " ...");
}

sub error() {
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
