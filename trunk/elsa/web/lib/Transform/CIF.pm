package Transform::CIF;
use Moose;
use Data::Dumper;
use CHI;
use DBI qw(:sql_types);
use Socket qw(inet_aton);
extends 'Transform';

our $Name = 'CIF';
our $Timeout = 10;
our $DefaultTimeOffset = 120;
our $Description = 'Cross-reference CIF';
sub description { return $Description }
our $Fields = { map { $_ => 1 } qw(srcip dstip site hostname) };
# Whois transform plugin
has 'name' => (is => 'rw', isa => 'Str', required => 1, default => $Name);
has 'cache' => (is => 'rw', isa => 'Object', required => 1);
has 'known_subnets' => (is => 'rw', isa => 'HashRef');
has 'known_orgs' => (is => 'rw', isa => 'HashRef');

sub BUILD {
	my $self = shift;
	
	if ($self->conf->get('transforms/whois/known_subnets')){
		$self->known_subnets($self->conf->get('transforms/whois/known_subnets'));
	}
	if ($self->conf->get('transforms/whois/known_orgs')){
		$self->known_orgs($self->conf->get('transforms/whois/known_orgs'));
	}
		
	my $cif = DBI->connect($self->conf->get('connectors/cif/dsn', '', ''), 
		{ 
			RaiseError => 1,
			mysql_multi_statements => 1,
			mysql_bind_type_guessing => 1, 
		}) or die($DBI::errstr);
	my ($query, $sth);
	$query = 'SELECT * FROM url, domain WHERE MATCH(?)';
	$sth = $cif->prepare($query);
	$query = 'SELECT * FROM infrastructure WHERE MATCH(?) AND subnet_start <= ? AND subnet_end >= ?';
	my $ip_sth = $cif->prepare($query);
	
	my $keys = {};
	if (scalar @{ $self->args }){
		foreach my $arg (@{ $self->args }){
			$keys->{$arg} = 1;
		}
	}
	else {
		$keys = { srcip => 1, dstip => 1 };
	}
	
	RECORD_LOOP: foreach my $datum (@{ $self->data }){
		$datum->{transforms}->{$Name} = {};
		foreach my $key (keys %{ $datum }){
			if ($keys->{$key} and $Fields->{ $key }){
				$datum->{transforms}->{$Name}->{$key} = {};
				my $info = $self->cache->get($datum->{$key});
				if ($info){
					$datum->{transforms}->{$Name}->{$key} = $info;
					#$self->log->trace('using cached value for ' . $datum->{$key});
					next;
				}
				
				my $row;
				# Handle IP's
				if ($datum->{$key} =~ /^(\d{1,3}\.\d{1,3}\.)\d{1,3}\.\d{1,3}$/){
					next if $self->_check_local($datum->{$key});
					$self->log->trace('checking ' . $datum->{$key});
					my $first_octets = $1;
					my $ip_int = unpack('N*', inet_aton($datum->{$key}));
					$ip_sth->bind_param(1, '@address ' . $first_octets . '* @description -search @alternativeid -www.alexa.com @alternativeid -support.clean-mx.de');
					$ip_sth->bind_param(2, $ip_int, SQL_INTEGER);
					$ip_sth->bind_param(3, $ip_int, SQL_INTEGER);
					$ip_sth->execute;
					$row = $ip_sth->fetchrow_hashref;
					if ($row){
						foreach my $col (keys %$row){
							$datum->{transforms}->{$Name}->{$key}->{$col} = $row->{$col};
						}
						$self->cache->set($datum->{$key}, $datum->{transforms}->{$Name}->{$key});
						next RECORD_LOOP;
					}
				}
				
				$sth->execute($datum->{$key} . ' -@description search');
				$row = $sth->fetchrow_hashref;
			
				unless ($row){
					$self->cache->set($datum->{$key}, {});
					next;
				}
				
				foreach my $col (keys %$row){
					$datum->{transforms}->{$Name}->{$key}->{$col} = $row->{$col};
				}
				$self->cache->set($datum->{$key}, $datum->{transforms}->{$Name}->{$key});
				next RECORD_LOOP;
			}
		}
	}
	
	return 1;
}

sub _check_local {
	my $self = shift;
	my $ip = shift;
	my $ip_int = unpack('N*', inet_aton($ip));
	
	return unless $ip_int and $self->known_subnets and $self->known_orgs;
	
	foreach my $start (keys %{ $self->known_subnets }){
		if (unpack('N*', inet_aton($start)) <= $ip_int 
			and unpack('N*', inet_aton($self->known_subnets->{$start}->{end})) >= $ip_int){
			return 1;
		}
	}
}

1;

__END__

#sub BUILDARGS {
#	my $class = shift;
#	my $params = $class->SUPER::BUILDARGS(@_);
#	$params->{cv} = AnyEvent->condvar;
#	return $params;
#}

sub BUILD {
	my $self = shift;
	
	my $keys = {};
	if (scalar @{ $self->args }){
		foreach my $arg (@{ $self->args }){
			$keys->{$arg} = 1;
		}
	}
	else {
		$keys = { srcip => 1, dstip => 1 };
	}
	
	if ($self->conf->get('transforms/whois/known_subnets')){
		$self->known_subnets($self->conf->get('transforms/whois/known_subnets'));
	}
	if ($self->conf->get('transforms/whois/known_orgs')){
		$self->known_orgs($self->conf->get('transforms/whois/known_orgs'));
	}	
	
	foreach my $datum (@{ $self->data }){
		$datum->{transforms}->{$Name} = {};
		
		$self->cv(AnyEvent->condvar);
		$self->cv->begin;
		foreach my $key (keys %{ $datum }){
			if ($keys->{$key}){
				$datum->{transforms}->{$Name}->{$key} = {};
				$self->_query($datum, $key, $datum->{$key});
			}
		}
		
		$self->cv->end;
		$self->cv->recv;
	}
	
	return $self;
}

sub _check_local {
	my $self = shift;
	my $ip = shift;
	my $ip_int = unpack('N*', inet_aton($ip));
	
	return unless $ip_int and $self->known_subnets and $self->known_orgs;
	
	foreach my $start (keys %{ $self->known_subnets }){
		if (unpack('N*', inet_aton($start)) <= $ip_int 
			and unpack('N*', inet_aton($self->known_subnets->{$start}->{end})) >= $ip_int){
			$self->log->trace('using local org');
			return 1;
		}
	}
}

sub _query {
	my $self = shift;
	my $datum = shift;
	my $key = shift;
	my $query = shift;
	
	if ($self->_check_local($query)){
		$datum->{transforms}->{$Name}->{$key} = {};
		return;
	}
	
	$self->cv->begin;
	
	$query = url_encode($query);
	my $url;
	if ($self->conf->get('transforms/cif/server_ip')){
		$url = sprintf('http://%s/api/%s?apikey=%s&fmt=json', 
			$self->conf->get('transforms/cif/server_ip'), $query, 
			$self->conf->get('transforms/cif/apikey'));
	}
	elsif ($self->conf->get('transforms/cif/base_url')){
		$url = sprintf('%s/api/%s?apikey=%s&fmt=json', 
			$self->conf->get('transforms/cif/base_url'), $query, 
			$self->conf->get('transforms/cif/apikey'));
	}
	else {
		die('server_ip nor base_url configured');
	}
	
	my $info = $self->cache->get($url, expire_if => sub {
		my $obj = $_[0];
		eval {
			my $data = $obj->value;
			#$self->log->debug('data: ' . Dumper($data));
			unless (scalar keys %{ $data }){
				$self->log->debug('expiring ' . $url);
				return 1;
			}
		};
		if ($@){
			$self->log->debug('error: ' . $@ . 'value: ' . Dumper($obj->value) . ', expiring ' . $url);
			return 1;
		}
		return 0;
	});
	if ($info){
		$datum->{transforms}->{$Name}->{$key} = $info;
		$self->cv->end;
		return;
	}
	
	$self->log->debug('getting ' . $url);
	my $headers = {
		Accept => 'application/json',
	};
	if ($self->conf->get('transforms/cif/server_name')){
		$headers->{Host} = $self->conf->get('transforms/cif/server_name');
	}
	http_request GET => $url, headers => $headers, sub {
		my ($body, $hdr) = @_;
		my $data;
		eval {
			$data = decode_json($body);
		};
		if ($@){
			$self->log->error($@ . 'hdr: ' . Dumper($hdr) . ', url: ' . $url . ', body: ' . ($body ? $body : ''));
			$self->cv->end;
			return;
		}
				
		if ($data and ref($data) eq 'HASH' and $data->{status} eq '200' and $data->{data}->{feed} and $data->{data}->{feed}->{entry}){
			foreach my $entry ( @{ $data->{data}->{feed}->{entry}} ){
				my $cif_datum = {};
				if ($entry->{Incident}){
					if ($entry->{Incident}->{Assessment}){
						if ($entry->{Incident}->{Assessment}->{Impact}){
							$self->log->debug('$entry' . Dumper($entry));
							if (ref($entry->{Incident}->{Assessment}->{Impact})){
								$cif_datum->{type} = $entry->{Incident}->{Assessment}->{Impact}->{content};
								$cif_datum->{severity} = $entry->{Incident}->{Assessment}->{Impact}->{severity};
							}
							else {
								$cif_datum->{type} = $entry->{Incident}->{Assessment}->{Impact};
								$cif_datum->{severity} = 'low';
							}
						}
						if ($entry->{Incident}->{Assessment}->{Confidence}){
							$cif_datum->{confidence} = $entry->{Incident}->{Assessment}->{Confidence}->{content};
						}
					}
					
					$cif_datum->{timestamp} = $entry->{Incident}->{DetectTime};
					
					if ($entry->{Incident}->{EventData}){
						if ($entry->{Incident}->{EventData}->{Flow}){
							if ($entry->{Incident}->{EventData}->{Flow}->{System}){
								if ($entry->{Incident}->{EventData}->{Flow}->{System}->{Node}){
									if ($entry->{Incident}->{EventData}->{Flow}->{System}->{Node}->{Address}){
										my $add = $entry->{Incident}->{EventData}->{Flow}->{System}->{Node}->{Address};
										if (ref($add) eq 'HASH'){
											$cif_datum->{ $add->{'ext-category'} } = $add->{content};
										}
										else {
											$cif_datum->{ip} = $add;
										}
									}
								}
								if ($entry->{Incident}->{EventData}->{Flow}->{System}->{AdditionalData}){
									if (ref($entry->{Incident}->{EventData}->{Flow}->{System}->{AdditionalData}) eq 'ARRAY'){
										$cif_datum->{description} = '';
										foreach my $add (@{ $entry->{Incident}->{EventData}->{Flow}->{System}->{AdditionalData} }){
											$cif_datum->{description} .= $add->{meaning} . '=' . $add->{content} . ' ';
										}
									}
									elsif (ref($entry->{Incident}->{EventData}->{Flow}->{System}->{AdditionalData}) eq 'HASH'){
										my $add = $entry->{Incident}->{EventData}->{Flow}->{System}->{AdditionalData};
										$cif_datum->{description} = $add->{meaning} . '=' . $add->{content};
									}
									else {
										$cif_datum->{description} = $entry->{Incident}->{EventData}->{Flow}->{System}->{AdditionalData};
									}
								}
							}
						}
					}
					
					if ($entry->{Incident}->{AlternativeID}){
						if ($entry->{Incident}->{AlternativeID}->{IncidentID}){
							if ($entry->{Incident}->{AlternativeID}->{IncidentID}->{content}){
								$cif_datum->{reference} = $entry->{Incident}->{AlternativeID}->{IncidentID}->{content};
							}
						}
					}
					
					if ($entry->{Incident}->{Description}){
						$cif_datum->{reason} = $entry->{Incident}->{Description};
					}
					foreach my $cif_key (keys %$cif_datum){
						$datum->{transforms}->{$Name}->{$key}->{$cif_key} ||= {};
						$datum->{transforms}->{$Name}->{$key}->{$cif_key}->{ $cif_datum->{$cif_key} } = 1;
					}
					#$datum->{transforms}->{$Name}->{$key} = $cif_datum;
					#$self->cache->set($url, $cif_datum);
				}
			}
			my $final = {};
			foreach my $cif_key (sort keys %{ $datum->{transforms}->{$Name}->{$key} }){
				$final->{$cif_key} = join(' ', sort keys %{ $datum->{transforms}->{$Name}->{$key}->{$cif_key} });
			}
			$datum->{transforms}->{$Name}->{$key} = $final;
					
			$self->cache->set($url, $datum->{transforms}->{$Name}->{$key});
		}
		$self->cv->end;
	};
}
 
1;