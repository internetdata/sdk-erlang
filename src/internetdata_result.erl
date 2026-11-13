%% @doc Turns a decoded JSON body into the maps the client hands back.
%%
%% <b>Only a name the SPEC defines, at the POSITION the spec defines it, becomes
%% an atom.</b> Everything else keeps its binary key. That is not a style
%% preference: `schema', `sample' and `size' are keyed by format, the rows under
%% `sample' by the dataset's own column names, and an AS answer's `whois' by the
%% registry's own field names, all of which are the server's to choose. Erlang's
%% atom table is capped at 1,048,576 entries and is never garbage collected, so
%% minting an atom per key off a body like that is a remote VM kill rather than a
%% leak.
%%
%% The consequence to read the results by: `maps:get(base, Db)' for a documented
%% field, `maps:get(&lt;&lt;"csvgz"&gt;&gt;, Size)' for anything keyed by format or by a
%% dataset column.
%%
%% <b>Absent is not false.</b> A key that is ABSENT from a lookup answer is one
%% your plan does not include, the paid members inside a shared object
%% (`location', `asn', `company', `abuse') included. It never means "we could
%% not check", so an absent key and `false' are genuinely different answers, and
%% `maps:get(is_hosting, Result, undefined)' is how you tell them apart. A detail
%% map that is present but empty (`#{}', Web IP's `[]') means the flag above it
%% is false. `raw' holds the answer as the wire carried it.
-module(internetdata_result).

-export([from_wire/1, bogon/1, asn/1, domain/1, entitlement/1]).
-export([databases/1, metadata/1, checksums/1, downloads/1]).

-export_type([result/0, asn_result/0, domain_result/0, entitlement/0]).

%% A tag here would be attached to the next FUNCTION by edoc and collide with its
%% own, which breaks doc chunk generation outright, so the prose lives on the
%% module. `:=' marks a key every answer carries, `=>' one a plan may leave out.
-type result() :: #{
    raw := map(),
    ip := binary(),
    is_bogon := boolean(),
    is_vpn => boolean(),
    is_tor := boolean(),
    is_relay := boolean(),
    is_resproxy => boolean(),
    is_dcproxy => boolean(),
    is_mobproxy => boolean(),
    is_pubproxy => boolean(),
    is_hosting => boolean(),
    is_cdn => boolean(),
    is_anycast := boolean(),
    is_carrier := boolean(),
    is_satellite := boolean(),
    is_ssh := boolean(),
    is_smtp := boolean(),
    is_web := boolean(),
    is_dns_resolver := boolean(),
    is_bittorrent := boolean(),
    vpn => class(),
    tor := class(),
    relay := class(),
    resproxy => proxy(),
    dcproxy => proxy(),
    mobproxy => proxy(),
    pubproxy => pubproxy(),
    hosting => class(),
    cdn => class(),
    carrier => carrier(),
    satellite => satellite(),
    ssh => ssh(),
    smtp => smtp(),
    web => [web()],
    dns_resolver => dns_resolver(),
    bittorrent => bittorrent(),
    location := location(),
    asn := asn(),
    company := company(),
    hostname := binary(),
    abuse := abuse(),
    whois => whois(),
    rwhois => rwhois(),
    hosted_domains => hosted_domains(),
    trial_expired => boolean()
}.
-type class() :: #{
    provider => binary(),
    provider_name => binary(),
    confidence => binary(),
    last_seen => binary()
}.
-type proxy() :: #{
    provider => binary(),
    provider_name => binary(),
    first_seen => binary(),
    last_seen => binary(),
    hits => integer(),
    hits_days_pct => integer(),
    providers_num => integer()
}.
-type pubproxy() :: #{
    entry => boolean(),
    exit => boolean(),
    protocols => [binary()],
    num_ports => integer(),
    num_proxies => integer(),
    last_seen => binary(),
    last_usable => binary()
}.
-type carrier() :: #{
    name => binary(),
    mcc => binary(),
    mnc => binary(),
    country => binary(),
    confidence => binary()
}.
-type satellite() :: #{
    provider => binary(),
    provider_name => binary(),
    orbit => binary(),
    segment => binary(),
    country => binary(),
    asn => integer(),
    confidence => binary()
}.
-type ssh() :: #{
    port => integer(),
    banner => binary(),
    host_key_fp => binary(),
    session_ok => boolean(),
    first_seen => binary(),
    last_seen => binary()
}.
-type smtp() :: #{
    port => integer(),
    banner => binary(),
    session_ok => boolean(),
    first_seen => binary(),
    last_seen => binary()
}.
-type web() :: #{
    port := integer(),
    tls_ok := boolean(),
    session_ok := boolean(),
    status_code := integer(),
    server := binary(),
    location := binary(),
    title := binary(),
    cert_subject_cn := binary(),
    cert_subject_o := binary(),
    cert_issuer_dn := binary(),
    cert_browser_trusted := boolean(),
    tls_version := binary(),
    first_seen := binary(),
    last_seen := binary()
}.
-type dns_resolver() :: #{
    port => integer(),
    recursion_available => boolean(),
    rcode => integer(),
    answer_correct => boolean(),
    first_seen => binary(),
    last_seen => binary()
}.
-type bittorrent() :: #{
    verified => boolean(),
    id_matches_ip => boolean(),
    first_seen => binary(),
    last_seen => binary(),
    last_reachable => binary(),
    days_seen => integer(),
    num_ports => integer(),
    peak_num_ports => integer(),
    indexer => boolean(),
    clients => [binary()]
}.
-type location() :: #{
    continent := binary(),
    continent_name := binary(),
    country := binary(),
    country_name := binary(),
    timezone := binary(),
    currency_code := binary(),
    currency_name := binary(),
    currency_symbol := binary(),
    flag_emoji := binary(),
    flag_unicode := binary(),
    region => binary(),
    region_code => binary(),
    city => binary(),
    postal_code => binary(),
    latitude => number(),
    longitude => number(),
    accuracy_radius => integer(),
    geoname_id => binary(),
    dma_code => binary(),
    last_changed => binary()
}.
-type asn() :: #{
    asn := integer(),
    name := binary(),
    domain := binary(),
    type := binary(),
    prefix := binary(),
    country => binary(),
    rpki_status => binary()
}.
-type company() :: #{
    name := binary(),
    domain := binary(),
    type => binary(),
    country => binary()
}.
-type abuse() :: #{
    email := binary(),
    name => binary(),
    phone => binary(),
    address => binary(),
    country => binary(),
    network => binary(),
    validated => boolean(),
    unvalidated_since => binary()
}.
-type whois() :: #{
    id := binary(),
    name := binary(),
    org := binary(),
    country := binary(),
    status := binary(),
    source := binary(),
    domain := binary(),
    abuse_email := binary(),
    asn := integer()
}.
-type rwhois() :: #{
    id := binary(),
    name := binary(),
    country := binary(),
    source := binary(),
    domain := binary(),
    abuse_email := binary()
}.
-type hosted_domains() :: #{
    total := integer()
}.
-type asn_result() :: #{
    asn := integer(),
    name := binary(),
    country := binary(),
    registry := binary(),
    allocated := binary(),
    domain := binary(),
    type => binary(),
    num_ips => integer(),
    num_prefixes4 => integer(),
    num_prefixes6 => integer(),
    rpki_valid => integer(),
    rpki_invalid => integer(),
    rpki_not_found => integer(),
    whois => #{binary() => binary()},
    prefixes => [asn_prefix()],
    trial_expired => boolean()
}.
-type asn_prefix() :: #{
    prefix := binary(),
    peer_count := integer(),
    rpki_status := binary(),
    first_seen := binary(),
    country := binary(),
    size := integer(),
    other_origins := [integer()]
}.
-type domain_result() :: #{
    domain := binary(),
    is_registered := boolean(),
    is_disposable => boolean(),
    has_a := boolean(),
    has_aaaa := boolean(),
    has_mx := boolean(),
    has_ns := boolean(),
    has_cname := boolean(),
    dns => dns(),
    ip_ranges => ip_ranges(),
    disposable => disposable(),
    trial_expired => boolean()
}.
-type dns() :: #{
    a := [dns_address()],
    aaaa := [dns_address()],
    mx := [dns_mx()],
    ns := [dns_ns()],
    cname := [dns_cname()]
}.
-type dns_address() :: #{
    ip := binary(),
    last_seen := binary()
}.
-type dns_mx() :: #{
    priority := integer(),
    host := binary(),
    last_seen := binary()
}.
-type dns_ns() :: #{
    host := binary(),
    last_seen := binary()
}.
-type dns_cname() :: #{
    target := binary(),
    last_seen := binary()
}.
-type ip_ranges() :: #{
    domain := binary(),
    redirects_to := binary(),
    total := integer(),
    ipv4 := integer(),
    ranges := [ip_range()]
}.
-type ip_range() :: #{
    range := binary(),
    name := binary(),
    country := binary()
}.
-type disposable() :: #{
    confidence => binary(),
    providers => [binary()],
    first_seen => binary(),
    last_seen => binary()
}.
-type entitlement() :: #{
    org_id := binary(),
    apikey := entitlement_apikey(),
    plan := entitlement_plan(),
    usage := entitlement_usage()
}.
-type entitlement_apikey() :: #{
    id := binary(),
    expires := binary() | null,
    allowed_cidrs := [binary()]
}.
-type entitlement_plan() :: #{
    key := binary(),
    tier := binary()
}.
-type entitlement_usage() :: #{
    requests := integer(),
    quota := integer(),
    hard_limit := integer() | null,
    window_start := binary(),
    window_end := binary()
}.

%% @doc Translate a decoded lookup answer into a result.
%%
%% Folding over what the body HAS is what preserves absent-versus-false: a key
%% the server did not send cannot appear in the fold, so no plan-gated member
%% can be invented as `false'.
-spec from_wire(map()) -> result().
from_wire(Body) when is_map(Body) ->
    (decode(lookup, Body))#{raw => Body}.

%% @doc The answer a bogon gets, in the full shape the API serves on a paid plan:
%% every flag false, every detail empty (Web IP's list empty), every key of
%% `location', `asn', `company', `abuse', `whois' and `rwhois' empty or 0, no
%% hostname and no hosted domains, and `is_bogon' true.
%%
%% This is deliberately the WIDEST shape whatever your plan is, so a caller must
%% not infer which fields they are entitled to from a bogon answer.
%%
%% Built as a WIRE body and then mapped, so `raw' carries the same answer the
%% mapped keys do.
-spec bogon(binary()) -> result().
bogon(Ip) ->
    Flags = [<<"is_vpn">>, <<"is_tor">>, <<"is_relay">>, <<"is_resproxy">>, <<"is_dcproxy">>,
             <<"is_mobproxy">>, <<"is_pubproxy">>, <<"is_hosting">>, <<"is_cdn">>, <<"is_anycast">>,
             <<"is_carrier">>, <<"is_satellite">>, <<"is_ssh">>, <<"is_smtp">>, <<"is_web">>,
             <<"is_dns_resolver">>, <<"is_bittorrent">>],
    Details = [<<"vpn">>, <<"tor">>, <<"relay">>, <<"resproxy">>, <<"dcproxy">>, <<"mobproxy">>,
               <<"pubproxy">>, <<"hosting">>, <<"cdn">>, <<"carrier">>, <<"satellite">>, <<"ssh">>,
               <<"smtp">>, <<"dns_resolver">>, <<"bittorrent">>],
    Location = blank([<<"continent">>, <<"continent_name">>, <<"country">>, <<"country_name">>,
                      <<"timezone">>, <<"currency_code">>, <<"currency_name">>, <<"currency_symbol">>,
                      <<"flag_emoji">>, <<"flag_unicode">>, <<"region">>, <<"region_code">>, <<"city">>,
                      <<"postal_code">>, <<"geoname_id">>, <<"dma_code">>, <<"last_changed">>]),
    Asn = blank([<<"name">>, <<"domain">>, <<"type">>, <<"prefix">>, <<"country">>, <<"rpki_status">>]),
    Abuse = blank([<<"email">>, <<"name">>, <<"phone">>, <<"address">>, <<"country">>, <<"network">>,
                   <<"unvalidated_since">>]),
    Whois = blank([<<"id">>, <<"name">>, <<"org">>, <<"country">>, <<"status">>, <<"source">>, <<"domain">>,
                   <<"abuse_email">>]),
    Wire = (maps:merge(maps:from_keys(Flags, false), maps:from_keys(Details, #{})))#{
        <<"ip">> => Ip,
        <<"is_bogon">> => true,
        <<"web">> => [],
        <<"location">> => Location#{<<"latitude">> => 0, <<"longitude">> => 0, <<"accuracy_radius">> => 0},
        <<"asn">> => Asn#{<<"asn">> => 0},
        <<"company">> => blank([<<"name">>, <<"domain">>, <<"type">>, <<"country">>]),
        <<"hostname">> => <<>>,
        <<"abuse">> => Abuse#{<<"validated">> => false},
        <<"whois">> => Whois#{<<"asn">> => 0},
        <<"rwhois">> => blank([<<"id">>, <<"name">>, <<"country">>, <<"source">>, <<"domain">>,
                               <<"abuse_email">>]),
        <<"hosted_domains">> => #{<<"total">> => 0}
    },
    from_wire(Wire).

%% @doc An AS answer. `whois' is keyed by the registry's own field names, so its
%% keys stay binaries.
-spec asn(map()) -> asn_result().
asn(Wire) ->
    decode(asn_lookup, Wire).

%% @doc A domain answer.
-spec domain(map()) -> domain_result().
domain(Wire) ->
    decode(domain_lookup, Wire).

%% @doc What a key may spend, and what it has.
-spec entitlement(map()) -> entitlement().
entitlement(Wire) ->
    decode(entitlement, Wire).

%% @doc The catalog, one entry per dataset family.
-spec databases([map()]) -> [map()].
databases(Wire) when is_list(Wire) ->
    [decode(database, Entry) || Entry <- Wire, is_map(Entry)].

%% @doc One dataset's build document: schema, samples, row count, sizes.
-spec metadata(map()) -> map().
metadata(Wire) ->
    decode(metadata, Wire).

%% @doc Every digest published for one dataset file.
-spec checksums(map()) -> map().
checksums(Wire) ->
    decode(checksums, Wire).

%% @doc Recent download attempts, refusals included.
-spec downloads([map()]) -> [map()].
downloads(Wire) when is_list(Wire) ->
    [decode(download, Entry) || Entry <- Wire, is_map(Entry)].

decode(Context, Wire) when is_map(Wire) ->
    maps:fold(fun(Name, Value, Acc) -> member(Context, Name, Value, Acc) end, #{}, Wire);
decode(_Context, Wire) ->
    Wire.

member(Context, Name, Value, Acc) ->
    case key(Context, Name) of
        undefined -> Acc#{Name => Value};
        Key -> Acc#{Key => child(Context, Name, Value)}
    end.

%% The whole allowlist, one clause per name the spec gives a position. Written
%% out rather than derived, because it is the bound on every atom this library
%% can ever create and a derived one would be as wide as whatever it derived
%% from.
key(database, <<"base">>) -> base;
key(database, <<"name">>) -> name;
key(database, <<"summary">>) -> summary;
key(database, <<"standing">>) -> standing;
key(database, <<"open">>) -> open;
key(database, <<"license_type">>) -> license_type;
key(database, <<"starts">>) -> starts;
key(database, <<"expires">>) -> expires;
key(database, <<"renews_at">>) -> renews_at;
key(database, <<"notice_due_at">>) -> notice_due_at;
key(database, <<"versions">>) -> versions;
key(version, <<"id">>) -> id;
key(version, <<"version">>) -> version;
key(version, <<"summary">>) -> summary;
key(version, <<"formats">>) -> formats;
key(version, <<"sample_formats">>) -> sample_formats;
key(metadata, <<"id">>) -> id;
key(metadata, <<"update_freq">>) -> update_freq;
key(metadata, <<"updated">>) -> updated;
key(metadata, <<"entries">>) -> entries;
key(metadata, <<"schema">>) -> schema;
key(metadata, <<"sample">>) -> sample;
key(metadata, <<"size">>) -> size;
key(metadata, <<"sample_size">>) -> sample_size;
key(metadata, <<"sample_entries">>) -> sample_entries;
key(column, <<"name">>) -> name;
key(column, <<"type">>) -> type;
key(column, <<"description">>) -> description;
key(checksums, <<"md5">>) -> md5;
key(checksums, <<"sha1">>) -> sha1;
key(checksums, <<"sha256">>) -> sha256;
key(checksums, <<"sha512">>) -> sha512;
key(download, <<"dataset_id">>) -> dataset_id;
key(download, <<"format">>) -> format;
key(download, <<"outcome">>) -> outcome;
key(download, <<"sample">>) -> sample;
key(download, <<"open">>) -> open;
key(download, <<"bytes">>) -> bytes;
key(download, <<"http_status">>) -> http_status;
key(download, <<"apikey_id">>) -> apikey_id;
key(download, <<"client_ip">>) -> client_ip;
key(download, <<"user_agent">>) -> user_agent;
key(download, <<"created">>) -> created;
key(lookup, <<"ip">>) -> ip;
key(lookup, <<"is_bogon">>) -> is_bogon;
key(lookup, <<"is_vpn">>) -> is_vpn;
key(lookup, <<"is_tor">>) -> is_tor;
key(lookup, <<"is_relay">>) -> is_relay;
key(lookup, <<"is_resproxy">>) -> is_resproxy;
key(lookup, <<"is_dcproxy">>) -> is_dcproxy;
key(lookup, <<"is_mobproxy">>) -> is_mobproxy;
key(lookup, <<"is_pubproxy">>) -> is_pubproxy;
key(lookup, <<"is_hosting">>) -> is_hosting;
key(lookup, <<"is_cdn">>) -> is_cdn;
key(lookup, <<"is_anycast">>) -> is_anycast;
key(lookup, <<"is_carrier">>) -> is_carrier;
key(lookup, <<"is_satellite">>) -> is_satellite;
key(lookup, <<"is_ssh">>) -> is_ssh;
key(lookup, <<"is_smtp">>) -> is_smtp;
key(lookup, <<"is_web">>) -> is_web;
key(lookup, <<"is_dns_resolver">>) -> is_dns_resolver;
key(lookup, <<"is_bittorrent">>) -> is_bittorrent;
key(lookup, <<"vpn">>) -> vpn;
key(lookup, <<"tor">>) -> tor;
key(lookup, <<"relay">>) -> relay;
key(lookup, <<"resproxy">>) -> resproxy;
key(lookup, <<"dcproxy">>) -> dcproxy;
key(lookup, <<"mobproxy">>) -> mobproxy;
key(lookup, <<"pubproxy">>) -> pubproxy;
key(lookup, <<"hosting">>) -> hosting;
key(lookup, <<"cdn">>) -> cdn;
key(lookup, <<"carrier">>) -> carrier;
key(lookup, <<"satellite">>) -> satellite;
key(lookup, <<"ssh">>) -> ssh;
key(lookup, <<"smtp">>) -> smtp;
key(lookup, <<"web">>) -> web;
key(lookup, <<"dns_resolver">>) -> dns_resolver;
key(lookup, <<"bittorrent">>) -> bittorrent;
key(lookup, <<"location">>) -> location;
key(lookup, <<"asn">>) -> asn;
key(lookup, <<"company">>) -> company;
key(lookup, <<"hostname">>) -> hostname;
key(lookup, <<"abuse">>) -> abuse;
key(lookup, <<"whois">>) -> whois;
key(lookup, <<"rwhois">>) -> rwhois;
key(lookup, <<"hosted_domains">>) -> hosted_domains;
key(lookup, <<"trial_expired">>) -> trial_expired;
key(class, <<"provider">>) -> provider;
key(class, <<"provider_name">>) -> provider_name;
key(class, <<"confidence">>) -> confidence;
key(class, <<"last_seen">>) -> last_seen;
key(proxy, <<"provider">>) -> provider;
key(proxy, <<"provider_name">>) -> provider_name;
key(proxy, <<"first_seen">>) -> first_seen;
key(proxy, <<"last_seen">>) -> last_seen;
key(proxy, <<"hits">>) -> hits;
key(proxy, <<"hits_days_pct">>) -> hits_days_pct;
key(proxy, <<"providers_num">>) -> providers_num;
key(pubproxy, <<"entry">>) -> entry;
key(pubproxy, <<"exit">>) -> exit;
key(pubproxy, <<"protocols">>) -> protocols;
key(pubproxy, <<"num_ports">>) -> num_ports;
key(pubproxy, <<"num_proxies">>) -> num_proxies;
key(pubproxy, <<"last_seen">>) -> last_seen;
key(pubproxy, <<"last_usable">>) -> last_usable;
key(carrier, <<"name">>) -> name;
key(carrier, <<"mcc">>) -> mcc;
key(carrier, <<"mnc">>) -> mnc;
key(carrier, <<"country">>) -> country;
key(carrier, <<"confidence">>) -> confidence;
key(satellite, <<"provider">>) -> provider;
key(satellite, <<"provider_name">>) -> provider_name;
key(satellite, <<"orbit">>) -> orbit;
key(satellite, <<"segment">>) -> segment;
key(satellite, <<"country">>) -> country;
key(satellite, <<"asn">>) -> asn;
key(satellite, <<"confidence">>) -> confidence;
key(ssh, <<"port">>) -> port;
key(ssh, <<"banner">>) -> banner;
key(ssh, <<"host_key_fp">>) -> host_key_fp;
key(ssh, <<"session_ok">>) -> session_ok;
key(ssh, <<"first_seen">>) -> first_seen;
key(ssh, <<"last_seen">>) -> last_seen;
key(smtp, <<"port">>) -> port;
key(smtp, <<"banner">>) -> banner;
key(smtp, <<"session_ok">>) -> session_ok;
key(smtp, <<"first_seen">>) -> first_seen;
key(smtp, <<"last_seen">>) -> last_seen;
key(web, <<"port">>) -> port;
key(web, <<"tls_ok">>) -> tls_ok;
key(web, <<"session_ok">>) -> session_ok;
key(web, <<"status_code">>) -> status_code;
key(web, <<"server">>) -> server;
key(web, <<"location">>) -> location;
key(web, <<"title">>) -> title;
key(web, <<"cert_subject_cn">>) -> cert_subject_cn;
key(web, <<"cert_subject_o">>) -> cert_subject_o;
key(web, <<"cert_issuer_dn">>) -> cert_issuer_dn;
key(web, <<"cert_browser_trusted">>) -> cert_browser_trusted;
key(web, <<"tls_version">>) -> tls_version;
key(web, <<"first_seen">>) -> first_seen;
key(web, <<"last_seen">>) -> last_seen;
key(dns_resolver, <<"port">>) -> port;
key(dns_resolver, <<"recursion_available">>) -> recursion_available;
key(dns_resolver, <<"rcode">>) -> rcode;
key(dns_resolver, <<"answer_correct">>) -> answer_correct;
key(dns_resolver, <<"first_seen">>) -> first_seen;
key(dns_resolver, <<"last_seen">>) -> last_seen;
key(bittorrent, <<"verified">>) -> verified;
key(bittorrent, <<"id_matches_ip">>) -> id_matches_ip;
key(bittorrent, <<"first_seen">>) -> first_seen;
key(bittorrent, <<"last_seen">>) -> last_seen;
key(bittorrent, <<"last_reachable">>) -> last_reachable;
key(bittorrent, <<"days_seen">>) -> days_seen;
key(bittorrent, <<"num_ports">>) -> num_ports;
key(bittorrent, <<"peak_num_ports">>) -> peak_num_ports;
key(bittorrent, <<"indexer">>) -> indexer;
key(bittorrent, <<"clients">>) -> clients;
key(location, <<"continent">>) -> continent;
key(location, <<"continent_name">>) -> continent_name;
key(location, <<"country">>) -> country;
key(location, <<"country_name">>) -> country_name;
key(location, <<"timezone">>) -> timezone;
key(location, <<"currency_code">>) -> currency_code;
key(location, <<"currency_name">>) -> currency_name;
key(location, <<"currency_symbol">>) -> currency_symbol;
key(location, <<"flag_emoji">>) -> flag_emoji;
key(location, <<"flag_unicode">>) -> flag_unicode;
key(location, <<"region">>) -> region;
key(location, <<"region_code">>) -> region_code;
key(location, <<"city">>) -> city;
key(location, <<"postal_code">>) -> postal_code;
key(location, <<"latitude">>) -> latitude;
key(location, <<"longitude">>) -> longitude;
key(location, <<"accuracy_radius">>) -> accuracy_radius;
key(location, <<"geoname_id">>) -> geoname_id;
key(location, <<"dma_code">>) -> dma_code;
key(location, <<"last_changed">>) -> last_changed;
key(asn, <<"asn">>) -> asn;
key(asn, <<"name">>) -> name;
key(asn, <<"domain">>) -> domain;
key(asn, <<"type">>) -> type;
key(asn, <<"prefix">>) -> prefix;
key(asn, <<"country">>) -> country;
key(asn, <<"rpki_status">>) -> rpki_status;
key(company, <<"name">>) -> name;
key(company, <<"domain">>) -> domain;
key(company, <<"type">>) -> type;
key(company, <<"country">>) -> country;
key(abuse, <<"email">>) -> email;
key(abuse, <<"name">>) -> name;
key(abuse, <<"phone">>) -> phone;
key(abuse, <<"address">>) -> address;
key(abuse, <<"country">>) -> country;
key(abuse, <<"network">>) -> network;
key(abuse, <<"validated">>) -> validated;
key(abuse, <<"unvalidated_since">>) -> unvalidated_since;
key(whois, <<"id">>) -> id;
key(whois, <<"name">>) -> name;
key(whois, <<"org">>) -> org;
key(whois, <<"country">>) -> country;
key(whois, <<"status">>) -> status;
key(whois, <<"source">>) -> source;
key(whois, <<"domain">>) -> domain;
key(whois, <<"abuse_email">>) -> abuse_email;
key(whois, <<"asn">>) -> asn;
key(rwhois, <<"id">>) -> id;
key(rwhois, <<"name">>) -> name;
key(rwhois, <<"country">>) -> country;
key(rwhois, <<"source">>) -> source;
key(rwhois, <<"domain">>) -> domain;
key(rwhois, <<"abuse_email">>) -> abuse_email;
key(hosted_domains, <<"total">>) -> total;
key(asn_lookup, <<"asn">>) -> asn;
key(asn_lookup, <<"name">>) -> name;
key(asn_lookup, <<"country">>) -> country;
key(asn_lookup, <<"registry">>) -> registry;
key(asn_lookup, <<"allocated">>) -> allocated;
key(asn_lookup, <<"domain">>) -> domain;
key(asn_lookup, <<"type">>) -> type;
key(asn_lookup, <<"num_ips">>) -> num_ips;
key(asn_lookup, <<"num_prefixes4">>) -> num_prefixes4;
key(asn_lookup, <<"num_prefixes6">>) -> num_prefixes6;
key(asn_lookup, <<"rpki_valid">>) -> rpki_valid;
key(asn_lookup, <<"rpki_invalid">>) -> rpki_invalid;
key(asn_lookup, <<"rpki_not_found">>) -> rpki_not_found;
key(asn_lookup, <<"whois">>) -> whois;
key(asn_lookup, <<"prefixes">>) -> prefixes;
key(asn_lookup, <<"trial_expired">>) -> trial_expired;
key(asn_prefix, <<"prefix">>) -> prefix;
key(asn_prefix, <<"peer_count">>) -> peer_count;
key(asn_prefix, <<"rpki_status">>) -> rpki_status;
key(asn_prefix, <<"first_seen">>) -> first_seen;
key(asn_prefix, <<"country">>) -> country;
key(asn_prefix, <<"size">>) -> size;
key(asn_prefix, <<"other_origins">>) -> other_origins;
key(domain_lookup, <<"domain">>) -> domain;
key(domain_lookup, <<"is_registered">>) -> is_registered;
key(domain_lookup, <<"is_disposable">>) -> is_disposable;
key(domain_lookup, <<"has_a">>) -> has_a;
key(domain_lookup, <<"has_aaaa">>) -> has_aaaa;
key(domain_lookup, <<"has_mx">>) -> has_mx;
key(domain_lookup, <<"has_ns">>) -> has_ns;
key(domain_lookup, <<"has_cname">>) -> has_cname;
key(domain_lookup, <<"dns">>) -> dns;
key(domain_lookup, <<"ip_ranges">>) -> ip_ranges;
key(domain_lookup, <<"disposable">>) -> disposable;
key(domain_lookup, <<"trial_expired">>) -> trial_expired;
key(dns, <<"a">>) -> a;
key(dns, <<"aaaa">>) -> aaaa;
key(dns, <<"mx">>) -> mx;
key(dns, <<"ns">>) -> ns;
key(dns, <<"cname">>) -> cname;
key(dns_address, <<"ip">>) -> ip;
key(dns_address, <<"last_seen">>) -> last_seen;
key(dns_mx, <<"priority">>) -> priority;
key(dns_mx, <<"host">>) -> host;
key(dns_mx, <<"last_seen">>) -> last_seen;
key(dns_ns, <<"host">>) -> host;
key(dns_ns, <<"last_seen">>) -> last_seen;
key(dns_cname, <<"target">>) -> target;
key(dns_cname, <<"last_seen">>) -> last_seen;
key(ip_ranges, <<"domain">>) -> domain;
key(ip_ranges, <<"redirects_to">>) -> redirects_to;
key(ip_ranges, <<"total">>) -> total;
key(ip_ranges, <<"ipv4">>) -> ipv4;
key(ip_ranges, <<"ranges">>) -> ranges;
key(ip_range, <<"range">>) -> range;
key(ip_range, <<"name">>) -> name;
key(ip_range, <<"country">>) -> country;
key(disposable, <<"confidence">>) -> confidence;
key(disposable, <<"providers">>) -> providers;
key(disposable, <<"first_seen">>) -> first_seen;
key(disposable, <<"last_seen">>) -> last_seen;
key(entitlement, <<"org_id">>) -> org_id;
key(entitlement, <<"apikey">>) -> apikey;
key(entitlement, <<"plan">>) -> plan;
key(entitlement, <<"usage">>) -> usage;
key(entitlement_apikey, <<"id">>) -> id;
key(entitlement_apikey, <<"expires">>) -> expires;
key(entitlement_apikey, <<"allowed_cidrs">>) -> allowed_cidrs;
key(entitlement_plan, <<"key">>) -> key;
key(entitlement_plan, <<"tier">>) -> tier;
key(entitlement_usage, <<"requests">>) -> requests;
key(entitlement_usage, <<"quota">>) -> quota;
key(entitlement_usage, <<"hard_limit">>) -> hard_limit;
key(entitlement_usage, <<"window_start">>) -> window_start;
key(entitlement_usage, <<"window_end">>) -> window_end;
key(_Context, _Name) -> undefined.

%% VALUES are never turned into atoms either, however closed the spec's enum
%% looks: `standing', `license_type', `outcome' and `format' are all documented
%% as open on purpose, so a value added later stays readable by a client written
%% today. They arrive as binaries and stay that way.
child(database, <<"versions">>, Versions) when is_list(Versions) ->
    [decode(version, Version) || Version <- Versions];
%% Keyed by format, so the outer keys stay binary and only the columns under them
%% are documented names.
child(metadata, <<"schema">>, Schema) when is_map(Schema) ->
    maps:map(fun(_Format, Columns) -> columns(Columns) end, Schema);
child(Context, Name, Value) ->
    case nested(Context, Name) of
        undefined -> Value;
        Inner when is_list(Value) -> [decode(Inner, Entry) || Entry <- Value];
        Inner -> decode(Inner, Value)
    end.

%% The context each object member of a lookup or an entitlement answer is decoded
%% in, a list's entries one by one.
nested(lookup, <<"vpn">>) -> class;
nested(lookup, <<"tor">>) -> class;
nested(lookup, <<"relay">>) -> class;
nested(lookup, <<"resproxy">>) -> proxy;
nested(lookup, <<"dcproxy">>) -> proxy;
nested(lookup, <<"mobproxy">>) -> proxy;
nested(lookup, <<"pubproxy">>) -> pubproxy;
nested(lookup, <<"hosting">>) -> class;
nested(lookup, <<"cdn">>) -> class;
nested(lookup, <<"carrier">>) -> carrier;
nested(lookup, <<"satellite">>) -> satellite;
nested(lookup, <<"ssh">>) -> ssh;
nested(lookup, <<"smtp">>) -> smtp;
nested(lookup, <<"web">>) -> web;
nested(lookup, <<"dns_resolver">>) -> dns_resolver;
nested(lookup, <<"bittorrent">>) -> bittorrent;
nested(lookup, <<"location">>) -> location;
nested(lookup, <<"asn">>) -> asn;
nested(lookup, <<"company">>) -> company;
nested(lookup, <<"abuse">>) -> abuse;
nested(lookup, <<"whois">>) -> whois;
nested(lookup, <<"rwhois">>) -> rwhois;
nested(lookup, <<"hosted_domains">>) -> hosted_domains;
nested(asn_lookup, <<"prefixes">>) -> asn_prefix;
nested(domain_lookup, <<"dns">>) -> dns;
nested(domain_lookup, <<"ip_ranges">>) -> ip_ranges;
nested(domain_lookup, <<"disposable">>) -> disposable;
nested(dns, <<"a">>) -> dns_address;
nested(dns, <<"aaaa">>) -> dns_address;
nested(dns, <<"mx">>) -> dns_mx;
nested(dns, <<"ns">>) -> dns_ns;
nested(dns, <<"cname">>) -> dns_cname;
nested(ip_ranges, <<"ranges">>) -> ip_range;
nested(entitlement, <<"apikey">>) -> entitlement_apikey;
nested(entitlement, <<"plan">>) -> entitlement_plan;
nested(entitlement, <<"usage">>) -> entitlement_usage;
nested(_Context, _Name) ->
    undefined.

columns(Columns) when is_list(Columns) ->
    [decode(column, Column) || Column <- Columns];
columns(Other) ->
    Other.

blank(Keys) ->
    maps:from_keys(Keys, <<>>).
