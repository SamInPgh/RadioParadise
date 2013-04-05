package Plugins::RadioParadise::Plugin;

# TODO:
# - parse headers for icy-name =~ /radio paradise/ to not rely on shoutcast IDs

use strict;

use vars qw($VERSION);
use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;

use Slim::Menu::TrackInfo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.radioparadise',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_RADIO_PARADISE',
} );

my $prefs = preferences('server');

use constant PSD_URL => 'http://radioparadise.com/ajax_replace_sb.php?uid=';

# s13606 is the TuneIn ID for RP - Shoutcast URLs are recognized by the cover URL. Hopefully.
#my $radioUrlRegex = qr/(?:\.radioparadise\.com|id=s13606|shoutcast\.com.*id=(785339|101265|1595911|674983|308768|1604072|1646896|1695633|856611))/i;
my $radioUrlRegex = qr/(?:\.radioparadise\.com|id=s13606)/i;
my $songUrlRegex  = qr/radioparadise\.com\/temp\/[a-z0-9]+\.mp3/i;

sub initPlugin {
	my $class = shift;

	$VERSION = $class->_pluginDataFor('version');

	Slim::Menu::TrackInfo->registerInfoProvider( radioparadise => (
		isa => 'top',
		func   => \&nowPlayingInfoMenu,
	) );
	
	Slim::Formats::RemoteMetadata->registerProvider(
		match => $songUrlRegex,
		func  => sub {
			my ( $client, $url ) = @_;
			my $meta = $client->master->pluginData('rp_psd_trackinfo');
			return ($meta && $meta->{url} eq $url) ? $meta : undef;
		},
	);

	# don't know yet how to deal with initially cleaning the client's playlist from temporary tracks on mysb.com - if ever this is going there anyway :-)
	return if main::SLIM_SERVICE;
	
	Slim::Control::Request::subscribe(
		sub {
			$class->cleanupPlaylist($_[0]->client, 1);
		},
		[['client'], ['new']]
	);
}

sub nowPlayingInfoMenu {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;
	
	my $items = [];

	# only continue if we're playing RP (either URL matches, or the cover url is pointing to radioparadise.com)
	return unless $url =~ $radioUrlRegex || ($remoteMeta && $remoteMeta->{cover} && $remoteMeta->{cover} =~ /radioparadise\.com/);

	# add item to controll the current playlist
	if ( $client->playingSong && $client->playingSong->track->id == $track->id ) {
		$items = [{
			name => $client->string('PLUGIN_RADIO_PARADISE_PSD'),
			url  => \&_playSomethingDifferent,
			nextWindow => 'parent'
		}];
	}
	
	return $items;
}

sub _playSomethingDifferent {
	my ($client, $cb, $args) = @_;
	
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&_playSomethingDifferentSuccess,
		sub {
			$cb->({
				items => [{
					name => $client->string('PLUGIN_RADIO_PARADISE_PSD_FAILED'),
					showBriefly => 1,
				}]
			});
		},
		{
			timeout => 15,
			client  => $client,
			cb      => $cb,
		}
	);

	$http->get(PSD_URL . md5_hex( $client->uuid || $client->id ));
}

sub _playSomethingDifferentSuccess {
	my $http   = shift;
	my $client = $http->params('client');
	my $cb     = $http->params('cb');

	my $result = $http->content;
	
	# XXX - clean up JSON until this is fixed on the server side
#	$result =~ s/\s*([\{,])\s*(\w+)\s*:\s*'(.*?)'/$1"$2":"$3"/g; 

	main::DEBUGLOG && $log->debug("Got a new track: $result");

	$result = eval { from_json( $result ) };
	
	my $msg;
	
	if ( $@ ) {
		$log->error($@);
		$msg = $client->string('PLUGIN_RADIO_PARADISE_PSD_FAILED');
	}
	else {
		my $title = $result->{title} . ' - ' . $result->{artist};
		$result->{cover} =~ s/\/m\//\/l\// if $result->{cover};

		my $songIndex = Slim::Player::Source::streamingSongIndex($client) || 0;
		
		# keep track of old settings while we change them
		my $master = $client->master;
		$master->pluginData('rp_psd_prefs' => {
			repeat => Slim::Player::Playlist::repeat($master),
			transitionType => $prefs->client($master)->get('transitionType') || 0,
			transitionDuration => $prefs->client($master)->get('transitionDuration') || 2,
		});
		
		Slim::Player::Playlist::repeat($master, 0);
		$prefs->client($master)->set('transitionType', 5);
		$prefs->client($master)->set('transitionDuration', 2);
		
		$master->pluginData('rp_psd_trackinfo' => $result);
		Slim::Control::Request::executeRequest( $client, [ 'playlist', 'insert', $result->{url}, $title ] );
		Slim::Control::Request::executeRequest( $client, [ 'playlist', 'move', $songIndex + 1, $songIndex ] );
		Slim::Control::Request::executeRequest( $client, [ 'playlist', 'jump', $songIndex, $result->{fade_in} || 0, $result->{cue} || 0 ] );
		
		Slim::Control::Request::subscribe(\&_playingElseDone, [['playlist'], ['newsong']], $client);
		
		$msg = $client->string('JIVE_POPUP_NOW_PLAYING', $title);	
	}
	
	$cb->({
		items => [{
			name => $msg,
			showBriefly => 1,
		}]
	});
}

sub _playingElseDone {
	my $request = shift;
	__PACKAGE__->cleanupPlaylist($request->client);
}

sub cleanupPlaylist {
	my ( $class, $client, $force ) = @_;
	$client = $client->master;

	my $current = ($client->playingSong->track && $client->playingSong->track->url) || '';

	# restore some parameters when we're no longer playing any temporary track
	if ( $current !~ $songUrlRegex ) {
		main::DEBUGLOG && $log->debug("We're done playing something different. Back to the main stream.");
		Slim::Control::Request::unsubscribe(\&_playingElseDone, $client);
		$client->master->pluginData('rp_psd_trackinfo' => undef);

		my $oldPrefs = $client->pluginData('rp_psd_prefs');

		if ($oldPrefs) {
			Slim::Player::Playlist::repeat($client, $oldPrefs->{repeat});
			$prefs->client($client)->set('transitionType', $oldPrefs->{transitionType});
			$prefs->client($client)->set('transitionDuration', $oldPrefs->{transitionDuration});

			$client->pluginData('rp_psd_prefs' => undef);
		}
	}
	
	my $x = 0;
	foreach my $track (@{ Slim::Player::Playlist::playList($client) }) {
		my $url = (blessed $track ? $track->url : $track) || '';
		
		# remove temporary track, unless it's still playing
		if ( $force || ($current ne $url && $url =~ $songUrlRegex) ) {
			$client->execute([ 'playlist', 'delete', $x ]);
		}
		else {
			$x++;
		}
	}
}

sub _pluginDataFor {
	my $class = shift;
	my $key   = shift;

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class);

	if ($pluginData && ref($pluginData) && $pluginData->{$key}) {
		return $pluginData->{$key};
	}

	return undef;
}


1;