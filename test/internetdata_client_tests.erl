%% The client's own contract: what reaches the wire, how deep each response is
%% unwrapped, which keys are allowed to become atoms, and the lookups' cache,
%% batch and bogon handling, as distinct from the shared conformance corpus in
%% internetdata_conformance_tests.
-module(internetdata_client_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LIST_PATH, <<"/api/v2/database/list">>).
-define(METADATA_PATH, <<"/api/v2/database/metadata">>).
-define(CHECKSUM_PATH, <<"/api/v2/database/checksum">>).
-define(DOWNLOADS_PATH, <<"/api/v2/database/downloads">>).
-define(DOWNLOAD_PATH, <<"/api/v2/database/download">>).
-define(ENTITLEMENT_PATH, <<"/api/v1/entitlement">>).
-define(INVALID_TIMEOUTS, [0, -1, 1.5, foo, 4294967296, 1 bsl 64]).
%% Enough addresses for seven chunks of the batch endpoint's 1000, so a
%% concurrency bound has something to bound: one request per chunk, and only
%% the chunks overlap.
-define(ADDRS, [addr(N) || N <- lists:seq(0, 6000)]).

%% Today every endpoint is authenticated, so a keyless client only ever gets a
%% 401. It still has to BUILD and to send no credential at all: an empty key is
%% what a missing CI secret interpolates to, and `Bearer ' with nothing behind it
%% is a worse answer than no header.
a_keyless_client_sends_no_authorization_header_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => []}}}),
    [begin
         Client = internetdata:new(Options#{http => internetdata_stub:http(Stub)}),
         {ok, []} = internetdata:database_list(Client)
     end || Options <- [#{}, #{api_key => <<>>}, #{api_key => ""}]],

    [?assertEqual(false, lists:keyfind(<<"authorization">>, 1, Headers))
     || Headers <- internetdata_stub:headers_seen(Stub)],
    ?assertEqual(3, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% `false' is what `os:getenv/1' answers for an unset variable and `nil' what
%% Elixir's `System.get_env/1' does, so each is no key rather than a crash.
an_unset_environment_variable_is_no_key_test_() ->
    [{atom_to_list(Value), fun() ->
         Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => []}}}),
         Client = internetdata:new(#{api_key => Value, http => internetdata_stub:http(Stub)}),
         ?assertMatch(#{api_key := undefined}, Client),
         ?assertEqual({ok, []}, internetdata:database_list(Client)),
         [Headers] = internetdata_stub:headers_seen(Stub),
         ?assertEqual(false, lists:keyfind(<<"authorization">>, 1, Headers)),
         internetdata_stub:stop(Stub)
     end} || Value <- [false, nil]].

%% A blank key is what an unset secret interpolates to, and `Bearer' with a blank
%% behind it reads as a wrong key rather than as none.
a_blank_key_sends_no_authorization_header_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => []}}}),
    [begin
         {ok, []} = internetdata:database_list(internetdata:new(#{api_key => Key,
                                                                  http => internetdata_stub:http(Stub)}))
     end || Key <- [<<"   ">>, <<"\t">>, " \r\n "]],

    [?assertEqual(false, lists:keyfind(<<"authorization">>, 1, Headers))
     || Headers <- internetdata_stub:headers_seen(Stub)],
    ?assertEqual(3, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% A key read from a file ends with a newline; the blanks around a key are no
%% part of it.
a_key_is_sent_without_the_blanks_around_it_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => []}}}),
    [{ok, []} = internetdata:database_list(internetdata:new(#{api_key => Key, http => internetdata_stub:http(Stub)}))
     || Key <- [<<"sekrit\n">>, "sekrit\r\n", <<" \tsekrit ">>]],

    [?assertEqual({<<"authorization">>, <<"Bearer sekrit">>}, lists:keyfind(<<"authorization">>, 1, Headers))
     || Headers <- internetdata_stub:headers_seen(Stub)],
    internetdata_stub:stop(Stub).

%% httpc writes a header value out as it is given, so a control character inside
%% the key reached the wire, and a CR LF started a header of its own.
a_key_holding_a_control_character_is_refused_by_new_test() ->
    Stub = internetdata_stub:start(#{}),
    Keys = [<<"sekrit\r\nx-injected: 1">>, "sek\nrit", <<"sek", 1, "rit">>, <<"sekrit", 127>>, <<"sek\trit">>],
    [?assertError({badarg, {api_key, control_character}},
                  internetdata:new(#{api_key => Key, http => internetdata_stub:http(Stub)}))
     || Key <- Keys],
    ?assertEqual(0, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% Erlang orders every atom above every number, so `infinity' retried an outage
%% for ever.
a_retries_that_is_not_a_count_is_refused_by_new_test() ->
    [?assertError({badarg, {retries, V}}, internetdata:new(#{retries => V}))
     || V <- [infinity, -1, 1.5, foo, "2"]],
    [?assertMatch(#{retries := V}, internetdata:new(#{retries => V})) || V <- [0, 5]].

%% A library is seldom started, so the version has to come from loading it.
the_client_names_itself_and_this_release_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => []}}}),
    _ = application:unload(internetdata),

    {ok, []} = internetdata:database_list(client(Stub)),

    {ok, Vsn} = application:get_key(internetdata, vsn),
    [Headers] = internetdata_stub:headers_seen(Stub),
    ?assertEqual({<<"user-agent">>, iolist_to_binary(["internetdata-erlang/", Vsn])},
                 lists:keyfind(<<"user-agent">>, 1, Headers)),
    internetdata_stub:stop(Stub).

%% `new/0' is production with no key, which is the whole of the keyless surface.
new_with_no_options_at_all_builds_test() ->
    ?assertMatch(#{api_key := undefined}, internetdata:new()).

%% httpc fails every call at once on zero, runs one with no bound on a value it
%% ignores, and raises past 2^32 - 1 ms, so none of them may build a client.
a_timeout_out_of_range_is_refused_by_new_test() ->
    [?assertError({badarg, {timeout_ms, V}}, internetdata:new(#{timeout_ms => V}))
     || V <- ?INVALID_TIMEOUTS],
    [?assertMatch(#{timeout_ms := V}, internetdata:new(#{timeout_ms => V}))
     || V <- [1, 4294967295, infinity]].

%% Deleting the auth header, or sending it under the wrong scheme, passed a whole
%% suite in another language until something mutated it.
the_key_reaches_the_wire_as_a_bearer_token_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => []}}}),
    Client = internetdata:new(#{api_key => <<"sekrit">>, http => internetdata_stub:http(Stub)}),

    {ok, []} = internetdata:database_list(Client),

    [Headers] = internetdata_stub:headers_seen(Stub),
    ?assertEqual({<<"authorization">>, <<"Bearer sekrit">>},
                 lists:keyfind(<<"authorization">>, 1, Headers)),
    internetdata_stub:stop(Stub).

the_base_url_option_decides_where_requests_go_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => []}}}),
    Client = internetdata:new(#{api_key => <<"k">>, base_url => "https://staging.example",
                                http => internetdata_stub:http(Stub)}),

    {ok, []} = internetdata:database_list(Client),

    ?assertEqual(1, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% Every path appended starts with `/', so a slash left on the base URL doubles
%% into `//api/...', which is another path, and a second or third doubles too.
a_trailing_slash_on_the_base_url_never_doubles_into_the_path_test_() ->
    [{"base_url ending " ++ lists:duplicate(N, $/), fun() -> assert_slashes_dropped(N) end}
     || N <- [1, 2, 3]].

assert_slashes_dropped(N) ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => []}}}),
    Http = internetdata_stub:http(Stub),
    Parent = self(),
    Recording = fun(#{url := Url} = Request) ->
        Parent ! {requested, Url},
        Http(Request)
    end,
    Base = <<"https://h.example">>,
    Client = internetdata:new(#{base_url => <<Base/binary, (binary:copy(<<"/">>, N))/binary>>,
                                http => Recording}),

    _ = internetdata:lookup(Client, <<"8.8.8.8">>),
    _ = internetdata:lookup_asn(Client, 9009),
    _ = internetdata:lookup_domain(Client, <<"example.com">>),
    _ = internetdata:database_list(Client),
    _ = internetdata:oauth_metadata(Client),
    _ = internetdata:oauth_device_authorization(Client, <<"cli">>),

    ?assertEqual([<<Base/binary, "/8.8.8.8">>,
                  <<Base/binary, "/asn/9009">>,
                  <<Base/binary, "/domain/example.com">>,
                  <<Base/binary, "/api/v2/database/list">>,
                  <<Base/binary, "/.well-known/oauth-authorization-server">>,
                  <<Base/binary, "/oauth/device_authorization">>],
                 requested([])),
    internetdata_stub:stop(Stub).

%% One level down, under `databases'. Reading the top level answers a
%% server_error against a perfectly healthy API.
the_catalog_is_unwrapped_from_its_envelope_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => [family()]}}}),
    Client = client(Stub),

    {ok, [Database]} = internetdata:database_list(Client),

    ?assertEqual(<<"bogon_ip">>, maps:get(base, Database)),
    ?assertEqual(true, maps:get(open, Database)),
    ?assertEqual([<<"csvgz">>, <<"mmdb">>],
                 maps:get(formats, hd(maps:get(versions, Database)))),
    ?assertEqual(<<"bogon_ip_v1">>, maps:get(id, hd(maps:get(versions, Database)))),
    internetdata_stub:stop(Stub).

%% A proxy's HTML page, a cut-off body, `null' or an object without the member a
%% call returns is the server's failure, not an answer: a retried server_error
%% carrying the status, as any outage is.
a_2xx_the_call_cannot_read_is_a_retried_server_error_test_() ->
    Unreadable = [<<"<html>gateway</html>">>, <<"{\"databases\":">>, <<>>, <<"null">>, <<"[]">>,
                  <<"\"databases\"">>, <<"{}">>],
    Calls = [{<<"/1.1.1.1">>, <<"ip">>, fun(C) -> internetdata:lookup(C, <<"1.1.1.1">>) end},
             {<<"/asn/9009">>, <<"asn">>, fun(C) -> internetdata:lookup_asn(C, 9009) end},
             {<<"/domain/example.com">>, <<"domain">>,
              fun(C) -> internetdata:lookup_domain(C, <<"example.com">>) end},
             {<<"/myip">>, <<"ip">>, fun internetdata:my_ip/1},
             {?ENTITLEMENT_PATH, <<"org_id">>, fun internetdata:my_entitlement/1},
             {<<"/batch">>, <<"results">>, fun(C) ->
                 #{<<"1.1.1.1">> := One, <<"2.2.2.2">> := Two} =
                     internetdata:lookup_batch(C, [<<"1.1.1.1">>, <<"2.2.2.2">>]),
                 ?assertEqual(One, Two),
                 One
             end},
             {?LIST_PATH, <<"databases">>, fun internetdata:database_list/1},
             {?METADATA_PATH, <<"id">>, fun(C) -> internetdata:database_metadata(C, <<"bogon_ip_v1">>) end},
             {?CHECKSUM_PATH, <<"checksums">>,
              fun(C) -> internetdata:database_checksums(C, <<"bogon_ip_v1">>, mmdb) end},
             {?DOWNLOADS_PATH, <<"downloads">>, fun internetdata:database_downloads/1}],
    WrongTypes = [{?LIST_PATH, <<"{\"databases\":{}}">>}, {?LIST_PATH, <<"{\"databases\":null}">>},
                  {?LIST_PATH, <<"{\"databases\":[1]}">>}, {?CHECKSUM_PATH, <<"{\"checksums\":[]}">>},
                  {?DOWNLOADS_PATH, <<"{\"downloads\":{}}">>}, {?DOWNLOADS_PATH, <<"{\"downloads\":[null]}">>},
                  {?METADATA_PATH, <<"{\"id\":null}">>},
                  {<<"/batch">>, <<"{\"results\":[],\"errors\":[]}">>}, {<<"/batch">>, <<"{\"answers\":{}}">>}],
    [{binary_to_list(<<Path/binary, " ", Body/binary>>), fun() -> assert_unreadable(Path, Body, Call) end}
     || {Path, _Member, Call} <- Calls, Body <- Unreadable]
    ++ [{binary_to_list(<<Path/binary, " ", Body/binary>>),
         fun() -> assert_unreadable(Path, Body, call_for(Path, Calls)) end} || {Path, Body} <- WrongTypes]
    ++ [{"a 2xx in place of the download link's redirect", fun() ->
            assert_unreadable(?DOWNLOAD_PATH, <<"{}">>, fun(C) ->
                internetdata:database_download_url(C, <<"bogon_ip_v1">>, mmdb)
            end)
        end}].

%% A member of another type than the spec's, at any depth, is no answer either:
%% a version served as "3" was handed back as the binary, and an entry
%% without the members the spec requires as an empty map (1.10.0), and a
%% checksum answer without its `id' or `format' as its digests (1.11.3).
a_member_of_the_wrong_type_at_any_depth_is_a_retried_server_error_test_() ->
    Family = family(),
    [Version] = maps:get(<<"versions">>, Family),
    Listing = fun(F) -> #{<<"databases">> => [F]} end,
    Attempt = download(),
    Sums = #{<<"md5">> => <<"m">>, <<"sha1">> => <<"s1">>, <<"sha256">> => <<"s256">>, <<"sha512">> => <<"s512">>},
    Answer = #{<<"id">> => <<"bogon_ip_v1">>, <<"format">> => <<"mmdb">>, <<"checksums">> => Sums},
    Cases = [
        {?LIST_PATH, Listing(Family#{<<"versions">> => [Version#{<<"version">> => <<"3">>}]})},
        {?LIST_PATH, Listing(Family#{<<"versions">> => [Version#{<<"version">> => <<"x">>}]})},
        {?LIST_PATH, Listing(Family#{<<"versions">> => [Version#{<<"formats">> => [1]}]})},
        {?LIST_PATH, Listing(Family#{<<"versions">> => [maps:remove(<<"id">>, Version)]})},
        {?LIST_PATH, Listing(Family#{<<"versions">> => [1]})},
        {?LIST_PATH, Listing(Family#{<<"open">> => <<"yes">>})},
        {?LIST_PATH, Listing(Family#{<<"expires">> => 1})},
        {?LIST_PATH, Listing(Family#{<<"base">> => null})},
        {?LIST_PATH, Listing(#{})},
        {?METADATA_PATH, (metadata())#{<<"entries">> => <<"42">>}},
        {?METADATA_PATH, (metadata())#{<<"size">> => #{<<"csvgz">> => <<"760">>}}},
        {?METADATA_PATH, (metadata())#{<<"size">> => <<"760">>}},
        {?METADATA_PATH, (metadata())#{<<"schema">> => #{<<"csvgz">> => [#{<<"name">> => 1, <<"type">> => <<"t">>}]}}},
        {?METADATA_PATH, (metadata())#{<<"sample">> => #{<<"csvgz">> => [1]}}},
        {?METADATA_PATH, maps:remove(<<"updated">>, metadata())},
        {?CHECKSUM_PATH, Answer#{<<"checksums">> => Sums#{<<"sha256">> => 1}}},
        {?CHECKSUM_PATH, Answer#{<<"checksums">> => maps:remove(<<"sha512">>, Sums)}},
        {?CHECKSUM_PATH, maps:remove(<<"id">>, Answer)},
        {?CHECKSUM_PATH, maps:remove(<<"format">>, Answer)},
        {?CHECKSUM_PATH, Answer#{<<"id">> => null}},
        {?CHECKSUM_PATH, Answer#{<<"format">> => null}},
        {?CHECKSUM_PATH, Answer#{<<"id">> => 1}},
        {?CHECKSUM_PATH, Answer#{<<"format">> => 1}},
        {?DOWNLOADS_PATH, #{<<"downloads">> => [Attempt#{<<"bytes">> => <<"10">>}]}},
        {?DOWNLOADS_PATH, #{<<"downloads">> => [Attempt#{<<"open">> => <<"true">>}]}},
        {?DOWNLOADS_PATH, #{<<"downloads">> => [Attempt#{<<"created">> => null}]}}
    ],
    Calls = #{?LIST_PATH => fun internetdata:database_list/1,
              ?METADATA_PATH => fun(C) -> internetdata:database_metadata(C, <<"bogon_ip_v1">>) end,
              ?CHECKSUM_PATH => fun(C) -> internetdata:database_checksums(C, <<"bogon_ip_v1">>, mmdb) end,
              ?DOWNLOADS_PATH => fun internetdata:database_downloads/1},
    [begin
         Body = iolist_to_binary(json:encode(Wire)),
         {binary_to_list(<<Path/binary, " ", Body/binary>>),
          fun() -> assert_unreadable(Path, Body, maps:get(Path, Calls)) end}
     end || {Path, Wire} <- Cases].

%% Each lookup answer read whole, the members a plan may leave out included, so
%% each case below fails on its one change alone.
a_well_formed_lookup_answer_reads_test_() ->
    Calls = lookup_calls(),
    [{binary_to_list(Path), fun() ->
         Stub = internetdata_stub:start(#{Path => #{body => Wire}}),
         ?assertMatch({ok, _}, (maps:get(Path, Calls))(client(Stub))),
         internetdata_stub:stop(Stub)
     end} || {Path, Wire} <- [{<<"/1.1.1.1">>, lookup_ok()}, {<<"/myip">>, lookup_ok()},
                              {<<"/asn/9009">>, asn_ok()}, {<<"/domain/example.com">>, domain_ok()},
                              {?ENTITLEMENT_PATH, entitlement_ok()}]].

%% A member of another type than the spec's at any depth, a numeric string where
%% a number is due among them, and a member the spec requires that is missing:
%% each is an answer the call cannot read, never one handed back as served.
a_lookup_answer_of_the_wrong_shape_is_a_retried_server_error_test_() ->
    L = lookup_ok(),
    #{<<"location">> := Loc, <<"asn">> := Asn, <<"company">> := Company, <<"web">> := [Web],
      <<"pubproxy">> := Pub, <<"dcproxy">> := Dc, <<"whois">> := Whois} = L,
    A = asn_ok(),
    #{<<"prefixes">> := [Prefix]} = A,
    D = domain_ok(),
    #{<<"dns">> := Dns, <<"ip_ranges">> := Ranges} = D,
    E = entitlement_ok(),
    #{<<"apikey">> := Key, <<"plan">> := Plan, <<"usage">> := Usage} = E,
    Ip = <<"/1.1.1.1">>,
    Cases = [
        {Ip, L#{<<"is_bogon">> => <<"false">>}}, {Ip, L#{<<"ip">> => null}},
        {Ip, maps:remove(<<"location">>, L)}, {Ip, maps:remove(<<"hostname">>, L)},
        {Ip, maps:remove(<<"is_dns_resolver">>, L)}, {Ip, maps:remove(<<"relay">>, L)},
        {Ip, L#{<<"location">> => Loc#{<<"country">> => 1}}},
        {Ip, L#{<<"location">> => Loc#{<<"latitude">> => <<"1.5">>}}},
        {Ip, L#{<<"location">> => maps:remove(<<"timezone">>, Loc)}},
        {Ip, L#{<<"asn">> => Asn#{<<"asn">> => <<"5">>}}},
        {Ip, L#{<<"company">> => maps:remove(<<"domain">>, Company)}},
        {Ip, L#{<<"abuse">> => #{}}}, {Ip, L#{<<"tor">> => []}}, {Ip, L#{<<"web">> => [1]}},
        {Ip, L#{<<"web">> => [maps:remove(<<"port">>, Web)]}},
        {Ip, L#{<<"pubproxy">> => Pub#{<<"protocols">> => [null]}}},
        {Ip, L#{<<"dcproxy">> => Dc#{<<"hits">> => <<"3">>}}},
        {Ip, L#{<<"hosted_domains">> => #{<<"total">> => <<"3">>}}},
        {Ip, L#{<<"whois">> => maps:remove(<<"asn">>, Whois)}},
        {Ip, L#{<<"trial_expired">> => <<"true">>}},
        {<<"/myip">>, L#{<<"is_tor">> => <<"no">>}},
        {<<"/asn/9009">>, A#{<<"asn">> => <<"9009">>}}, {<<"/asn/9009">>, maps:remove(<<"registry">>, A)},
        {<<"/asn/9009">>, A#{<<"prefixes">> => [1]}},
        {<<"/asn/9009">>, A#{<<"prefixes">> => [Prefix#{<<"other_origins">> => [<<"x">>]}]}},
        {<<"/asn/9009">>, A#{<<"whois">> => #{<<"abuse_email">> => 1}}},
        {<<"/domain/example.com">>, D#{<<"is_registered">> => <<"yes">>}},
        {<<"/domain/example.com">>, maps:remove(<<"has_mx">>, D)},
        {<<"/domain/example.com">>,
         D#{<<"dns">> => Dns#{<<"a">> => [#{<<"ip">> => 1, <<"last_seen">> => <<"x">>}]}}},
        {<<"/domain/example.com">>, D#{<<"ip_ranges">> => Ranges#{<<"ranges">> => [#{}]}}},
        {<<"/domain/example.com">>, D#{<<"disposable">> => #{<<"providers">> => [1]}}},
        {?ENTITLEMENT_PATH, E#{<<"usage">> => Usage#{<<"requests">> => <<"1">>}}},
        {?ENTITLEMENT_PATH, E#{<<"apikey">> => Key#{<<"allowed_cidrs">> => [1]}}},
        {?ENTITLEMENT_PATH, E#{<<"plan">> => Plan#{<<"tier">> => 1}}},
        {?ENTITLEMENT_PATH, E#{<<"usage">> => Usage#{<<"window_start">> => <<"x">>}}},
        {?ENTITLEMENT_PATH, E#{<<"apikey">> => Key#{<<"expires">> => <<"monday">>}}},
        {?ENTITLEMENT_PATH, maps:remove(<<"plan">>, E)}
    ],
    Calls = lookup_calls(),
    [begin
         Body = iolist_to_binary(json:encode(Wire)),
         {binary_to_list(<<Path/binary, " ", Body/binary>>),
          fun() -> assert_unreadable(Path, Body, maps:get(Path, Calls)) end}
     end || {Path, Wire} <- Cases].

lookup_calls() ->
    #{<<"/1.1.1.1">> => fun(C) -> internetdata:lookup(C, <<"1.1.1.1">>) end,
      <<"/myip">> => fun internetdata:my_ip/1,
      <<"/asn/9009">> => fun(C) -> internetdata:lookup_asn(C, 9009) end,
      <<"/domain/example.com">> => fun(C) -> internetdata:lookup_domain(C, <<"example.com">>) end,
      ?ENTITLEMENT_PATH => fun internetdata:my_entitlement/1}.

%% RFC 3339 alone, on a day that exists. Through 1.11.2 a date was checked as a
%% binary alone, so every one of these came back as served (measured 2026-10-29).
a_date_that_is_not_rfc_3339_is_a_retried_server_error_test_() ->
    DateTimes = [<<"2026-10-05">>, <<"2026-10-05T10:00:00">>, <<"2026-10-05T10:00:00+05">>,
                 <<"2026-10-05T10:00Z">>, <<"2026-10-05T10:00:00+0500">>, <<"2026-10-05T10:00:00+05:00:30">>,
                 <<"2026-10-05T24:00:00Z">>, <<"2026-10-05T10:60:00Z">>, <<"2026-10-05T10:00:60Z">>,
                 <<"2026-02-30T10:00:00Z">>, <<"2026-10-05T10:00:00+24:00">>, <<"2026-10-05T10:00:00+05:60">>,
                 <<" 2026-10-05T10:00:00Z">>, <<"2026-10-05T10:00:00Z ">>, <<"2026-10-05 10:00:00Z">>,
                 <<"2026-10-5T10:00:00Z">>, <<"+12026-10-05T10:00:00Z">>, <<"2026-10-05T10:00:00.Z">>,
                 <<"20261005T100000Z">>, <<"2026-10-05T10:00:00UTC">>, <<"x">>, <<"tomorrow">>, <<"monday">>,
                 <<>>, <<"2026-10-05T10:00:00Z\n">>, <<16#D9, 16#A2, "026-10-05T10:00:00Z">>],
    Dates = [<<"2026-10-05T10:00:00">>, <<"2026-10-05T10:00:00Z">>, <<"2026-02-30">>, <<"2026-11-31">>,
             <<"2026-13-01">>, <<"2026-10-5">>, <<"20261005">>, <<"2026-W41-1">>, <<"2026-278">>,
             <<" 2026-10-05">>, <<"+12026-10-05">>, <<"x">>, <<"tomorrow">>, <<"monday">>, <<>>,
             <<"2026-10-05\n">>, <<16#D9, 16#A2, "026-10-05">>, <<"2025-02-29">>, <<"1900-02-29">>],
    Listing = fun(Member, Value) -> #{<<"databases">> => [(family())#{Member => Value}]} end,
    Cases = [{?LIST_PATH, Listing(Member, Value)}
             || Value <- DateTimes, Member <- [<<"starts">>, <<"expires">>, <<"renews_at">>, <<"notice_due_at">>]]
        ++ [{?DOWNLOADS_PATH, #{<<"downloads">> => [(download())#{<<"created">> => Value}]}} || Value <- DateTimes]
        ++ [{?METADATA_PATH, (metadata())#{<<"updated">> => Value}} || Value <- Dates]
        ++ [{?ENTITLEMENT_PATH, entitlement_at(Member, Value)}
            || Value <- DateTimes, Member <- [<<"window_start">>, <<"window_end">>, <<"expires">>]],
    Calls = #{?LIST_PATH => fun internetdata:database_list/1,
              ?METADATA_PATH => fun(C) -> internetdata:database_metadata(C, <<"bogon_ip_v1">>) end,
              ?DOWNLOADS_PATH => fun internetdata:database_downloads/1,
              ?ENTITLEMENT_PATH => fun internetdata:my_entitlement/1},
    [begin
         Body = iolist_to_binary(json:encode(Wire)),
         {binary_to_list(<<Path/binary, " ", Body/binary>>),
          fun() -> assert_unreadable(Path, Body, maps:get(Path, Calls)) end}
     end || {Path, Wire} <- Cases].

%% Every spelling RFC 3339 allows stays an answer, lowercase `t' and `z' included.
a_date_in_any_rfc_3339_spelling_stays_an_answer_test() ->
    DateTimes = [<<"2026-10-05T10:00:00Z">>, <<"2026-10-05t10:00:00.5z">>, <<"2026-10-05T10:00:00-00:00">>,
                 <<"2026-10-05T10:00:00.123456789+05:30">>, <<"2024-02-29T23:59:59+23:59">>,
                 <<"0001-01-01T00:00:00Z">>, <<"2000-02-29T00:00:00Z">>],
    Dates = [<<"2026-10-05">>, <<"2024-02-29">>, <<"0099-12-31">>, <<"2000-02-29">>],
    lists:foreach(fun(Value) ->
        Stub = internetdata_stub:start(#{
            ?LIST_PATH => #{body => #{<<"databases">> => [(family())#{<<"starts">> => Value}]}},
            ?DOWNLOADS_PATH => #{body => #{<<"downloads">> => [(download())#{<<"created">> => Value}]}},
            ?ENTITLEMENT_PATH => #{body => entitlement_at(<<"window_start">>, Value)}}),
        Client = client(Stub),
        ?assertMatch({ok, [#{starts := Value}]}, internetdata:database_list(Client)),
        ?assertMatch({ok, [#{created := Value}]}, internetdata:database_downloads(Client)),
        ?assertMatch({ok, #{usage := #{window_start := Value}}}, internetdata:my_entitlement(Client)),
        internetdata_stub:stop(Stub)
    end, DateTimes),
    lists:foreach(fun(Value) ->
        Stub = internetdata_stub:start(#{?METADATA_PATH => #{body => (metadata())#{<<"updated">> => Value}}}),
        ?assertMatch({ok, #{updated := Value}}, internetdata:database_metadata(client(Stub), <<"bogon_ip_v1">>)),
        internetdata_stub:stop(Stub)
    end, Dates).

%% The nullable members stay answers when null, and the optional ones when
%% absent: refusing those would fail every refused download and every family
%% with no license.
nullable_and_optional_members_stay_an_answer_test() ->
    Family = maps:without([<<"license_type">>, <<"starts">>, <<"renews_at">>, <<"notice_due_at">>],
                          (family())#{<<"expires">> => null}),
    Attempt = (download())#{<<"bytes">> => null, <<"http_status">> => null, <<"apikey_id">> => null,
                            <<"client_ip">> => null, <<"user_agent">> => null},
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => [Family]}},
                                     ?METADATA_PATH => #{body => maps:remove(<<"sample">>, metadata())},
                                     ?DOWNLOADS_PATH => #{body => #{<<"downloads">> => [Attempt]}}}),
    Client = client(Stub),

    ?assertMatch({ok, [_]}, internetdata:database_list(Client)),
    ?assertMatch({ok, #{entries := 42}}, internetdata:database_metadata(Client, <<"bogon_ip_v1">>)),
    ?assertMatch({ok, [#{bytes := null}]}, internetdata:database_downloads(Client)),
    ?assertEqual(3, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

assert_unreadable(Path, Body, Call) ->
    Stub = internetdata_stub:start(#{Path => #{raw => Body}}),
    Client = internetdata:new(#{api_key => <<"k">>, retries => 1, http => internetdata_stub:http(Stub)}),

    ?assertMatch({error, #{kind := server_error, retryable := true, status := 200}}, Call(Client)),
    ?assertEqual(2, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

call_for(Path, Calls) ->
    {Path, _Member, Call} = lists:keyfind(Path, 1, Calls),
    Call.

%% v2's metadata IS the response, with no `data' member around it. v1 wraps, so
%% unwrapping one level here would answer `undefined' for every field.
metadata_is_read_from_the_top_level_test() ->
    Stub = internetdata_stub:start(#{?METADATA_PATH => #{body => metadata()}}),
    Client = client(Stub),

    {ok, Metadata} = internetdata:database_metadata(Client, <<"bogon_ip_v1">>),

    ?assertEqual(<<"bogon_ip_v1">>, maps:get(id, Metadata)),
    ?assertEqual(760, maps:get(<<"csvgz">>, maps:get(size, Metadata))),
    ?assertEqual(<<"2026-09-04">>, maps:get(updated, Metadata)),
    internetdata_stub:stop(Stub).

%% `schema' and `sample' are keyed by format and then, inside a sample row, by
%% the dataset's own column names. Only the documented column FIELDS become
%% atoms; everything the server named stays a binary key.
the_server_named_keys_stay_binaries_test() ->
    Stub = internetdata_stub:start(#{?METADATA_PATH => #{body => metadata()}}),
    Client = client(Stub),

    {ok, Metadata} = internetdata:database_metadata(Client, <<"bogon_ip_v1">>),

    [Column] = maps:get(<<"csvgz">>, maps:get(schema, Metadata)),
    ?assertEqual(<<"range_start">>, maps:get(name, Column)),
    ?assertEqual(<<"varchar">>, maps:get(type, Column)),
    [Row] = maps:get(<<"csvgz">>, maps:get(sample, Metadata)),
    ?assertEqual([<<"range_end">>, <<"range_start">>], lists:sort(maps:keys(Row))),
    internetdata_stub:stop(Stub).

%% The atom table is capped and never collected, so a body keyed by dataset
%% column names must not be able to grow it. 61 responses, each with distinct
%% keys nothing in the library mentions.
a_body_full_of_unknown_keys_mints_no_atoms_test() ->
    Stub = internetdata_stub:start(#{}),
    Client = client(Stub),
    _ = [decode_unknown(Client, N) || N <- lists:seq(1, 5)],

    Before = erlang:system_info(atom_count),
    _ = [decode_unknown(Client, N) || N <- lists:seq(100, 160)],
    After = erlang:system_info(atom_count),

    ?assertEqual(Before, After),
    internetdata_stub:stop(Stub).

decode_unknown(_Client, N) ->
    Suffix = integer_to_binary(N),
    Wire = #{<<"id">> => <<"d">>,
             <<"schema">> => #{<<"fmt_", Suffix/binary>> => [#{<<"col_", Suffix/binary>> => 1}]},
             <<"sample">> => #{<<"fmt_", Suffix/binary>> => [#{<<"row_", Suffix/binary>> => 1}]},
             <<"unknown_", Suffix/binary>> => true},
    internetdata_result:metadata(Wire).

%% Nested under `checksums'. Reading a top-level `sha256' shipped broken in
%% another binding, against an API that was answering correctly.
checksums_are_unwrapped_past_their_envelope_test() ->
    Body = #{<<"id">> => <<"bogon_ip_v1">>, <<"format">> => <<"csvgz">>,
             <<"checksums">> => #{<<"md5">> => <<"m">>, <<"sha1">> => <<"s1">>,
                                  <<"sha256">> => <<"s256">>, <<"sha512">> => <<"s512">>}},
    Stub = internetdata_stub:start(#{?CHECKSUM_PATH => #{body => Body}}),
    Client = client(Stub),

    {ok, Checksums} = internetdata:database_checksums(Client, <<"bogon_ip_v1">>, csvgz),

    ?assertEqual(<<"s256">>, maps:get(sha256, Checksums)),
    ?assertEqual([md5, sha1, sha256, sha512], lists:sort(maps:keys(Checksums))),
    internetdata_stub:stop(Stub).

the_download_history_is_unwrapped_and_keeps_its_nulls_test() ->
    Attempt = #{<<"dataset_id">> => <<"bogon_ip_v1">>, <<"format">> => <<"csvgz">>,
                <<"outcome">> => <<"denied">>, <<"sample">> => true, <<"open">> => false,
                <<"bytes">> => null,
                <<"http_status">> => 403, <<"apikey_id">> => null,
                <<"client_ip">> => <<"203.0.113.7">>, <<"user_agent">> => null,
                <<"created">> => <<"2026-09-04T10:00:00.000Z">>},
    Stub = internetdata_stub:start(#{?DOWNLOADS_PATH => #{body => #{<<"downloads">> => [Attempt]}}}),
    Client = client(Stub),

    {ok, [Download]} = internetdata:database_downloads(Client),

    ?assertEqual(<<"denied">>, maps:get(outcome, Download)),
    ?assertEqual(true, maps:get(sample, Download)),
    ?assertEqual(false, maps:get(open, Download)),
    %% A refusal moved no bytes and resolved no key. Turning either null into a
    %% zero or an empty string would invent an answer.
    ?assertEqual(null, maps:get(bytes, Download)),
    ?assertEqual(null, maps:get(apikey_id, Download)),
    internetdata_stub:stop(Stub).

%% Absent by default rather than sent as the API's own default, so the clamp and
%% the default stay the server's to change. The limit asked for is the one on
%% the wire.
a_limit_is_only_sent_when_it_is_asked_for_test() ->
    Stub = internetdata_stub:start(#{?DOWNLOADS_PATH => #{body => #{<<"downloads">> => []}}}),
    Http = internetdata_stub:http(Stub),
    Parent = self(),
    Recording = fun(#{url := Url} = Request) ->
        Parent ! {requested, Url},
        Http(Request)
    end,
    Client = internetdata:new(#{api_key => <<"k">>, http => Recording}),

    {ok, []} = internetdata:database_downloads(Client, #{limit => 7}),
    {ok, []} = internetdata:database_downloads(Client),
    {ok, []} = internetdata:database_downloads(Client, #{timeout_ms => 5000}),

    ?assertEqual([{?DOWNLOADS_PATH, [{<<"limit">>, <<"7">>}]},
                  {?DOWNLOADS_PATH, []},
                  {?DOWNLOADS_PATH, []}],
                 [path_and_query(Url) || Url <- requested([])]),
    internetdata_stub:stop(Stub).

a_build_goes_on_the_download_request_and_none_without_one_test() ->
    Stub = internetdata_stub:start(#{?DOWNLOAD_PATH => #{
        status => 302, headers => #{<<"Location">> => <<"http://127.0.0.1:9/blob">>}}}),
    Http = internetdata_stub:http(Stub),
    Parent = self(),
    Recording = fun(#{url := Url} = Request) ->
        Parent ! {requested, Url},
        Http(Request)
    end,
    Client = internetdata:new(#{api_key => <<"k">>, http => Recording, retries => 0}),
    Named = <<"20261105.0t53s5">>,

    {ok, _} = internetdata:database_download_url(Client, <<"bogon_ip_v1">>, csvgz, #{build => Named}),
    {ok, _} = internetdata:database_download_url(Client, <<"bogon_ip_v1">>, csvgz,
                                                 #{build => "20261105.0t53s5", timeout_ms => 5000}),
    %% Object storage is unreachable here, so the transfer fails after the link.
    {error, _} = internetdata:database_download_bytes(Client, <<"bogon_ip_v1">>, csvgz, #{build => Named}),
    {ok, _} = internetdata:database_download_url(Client, <<"bogon_ip_v1">>, csvgz, #{build => <<>>}),
    {ok, _} = internetdata:database_download_url(Client, <<"bogon_ip_v1">>, csvgz),

    WithBuild = {?DOWNLOAD_PATH, [{<<"id">>, <<"bogon_ip_v1">>}, {<<"format">>, <<"csvgz">>},
                                  {<<"build">>, Named}]},
    Live = {?DOWNLOAD_PATH, [{<<"id">>, <<"bogon_ip_v1">>}, {<<"format">>, <<"csvgz">>}]},
    ?assertEqual([WithBuild, WithBuild, WithBuild, Live, Live],
                 [Asked || {Path, _} = Asked <- [path_and_query(Url) || Url <- requested([])],
                           Path =:= ?DOWNLOAD_PATH]),
    internetdata_stub:stop(Stub).

a_bad_build_or_a_transfer_given_a_timeout_is_refused_before_any_request_test() ->
    Stub = internetdata_stub:start(#{}),
    Client = internetdata:new(#{api_key => <<"k">>, http => internetdata_stub:http(Stub)}),
    Path = filename:join(os:getenv("TMPDIR", "/tmp"), "internetdata-refused.csv.gz"),

    Refusals = [
        internetdata:database_download_url(Client, <<"bogon_ip_v1">>, csvgz, #{build => 20261105}),
        internetdata:database_download_bytes(Client, <<"bogon_ip_v1">>, csvgz, #{build => latest}),
        internetdata:database_download_bytes(Client, <<"bogon_ip_v1">>, csvgz, #{timeout_ms => 5000}),
        internetdata:database_download(Client, <<"bogon_ip_v1">>, csvgz, Path, #{timeout_ms => 5000})
    ],

    [?assertMatch({error, #{kind := bad_request, retryable := false}}, R) || R <- Refusals],
    ?assertEqual(0, internetdata_stub:calls(Stub)),
    ?assertNot(filelib:is_file(Path ++ ".part")),
    internetdata_stub:stop(Stub).

a_gone_build_is_a_bad_request_asked_once_test() ->
    Stub = internetdata_stub:start(#{?DOWNLOAD_PATH => #{
        status => 410, body => #{<<"rc">> => <<"BUILD_GONE">>}}}),
    Client = internetdata:new(#{api_key => <<"k">>, http => internetdata_stub:http(Stub), retries => 2}),

    ?assertMatch({error, #{kind := bad_request, retryable := false, message := <<"BUILD_GONE">>}},
                 internetdata:database_download_url(Client, <<"bogon_ip_v1">>, csvgz,
                                                    #{build => <<"20261029.aaaaaa">>})),
    ?assertEqual(1, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% A per-call bound httpc cannot wait on is refused as well, before it costs a
%% request.
a_per_call_timeout_out_of_range_is_refused_before_any_request_test() ->
    Stub = internetdata_stub:start(#{?DOWNLOADS_PATH => #{body => #{<<"downloads">> => []}}}),
    Client = client(Stub),

    [?assertMatch({Name, V, {error, #{kind := bad_request, retryable := false}}},
                  {Name, V, Call(#{timeout_ms => V})})
     || {Name, Call} <- [{database_downloads, fun(O) -> internetdata:database_downloads(Client, O) end}
                         | per_call(Client)],
        V <- ?INVALID_TIMEOUTS],
    ?assertEqual(0, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% Erlang orders every atom above every number, so `infinity' retried an outage
%% for ever; a call refuses one before any request, as it refuses a bad timeout,
%% a bogon and a cached address included.
a_per_call_retries_that_is_not_a_count_is_refused_before_any_request_test() ->
    Stub = internetdata_stub:start(routes([<<"1.1.1.1">>])),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub)}),
    {ok, _} = internetdata:lookup(Client, <<"1.1.1.1">>),
    Bogon = fun(O) -> internetdata:lookup(Client, <<"10.0.0.1">>, O) end,

    [?assertMatch({Name, V, {error, #{kind := bad_request, retryable := false}}},
                  {Name, V, Call(#{retries => V})})
     || {Name, Call} <- [{bogon, Bogon} | per_call(Client)], V <- [infinity, -1, 1.5, foo, "2"]],
    [?assertMatch({V, {error, #{kind := bad_request}}}, {V, Bogon(#{timeout_ms => V})}) || V <- ?INVALID_TIMEOUTS],
    ?assertEqual(1, internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

%% Every lookup call that takes per-call options, each answering one result.
per_call(Client) ->
    [{lookup, fun(O) -> internetdata:lookup(Client, <<"1.1.1.1">>, O) end},
     {lookup_asn, fun(O) -> internetdata:lookup_asn(Client, 9009, O) end},
     {lookup_domain, fun(O) -> internetdata:lookup_domain(Client, <<"example.com">>, O) end},
     {my_ip, fun(O) -> internetdata:my_ip(Client, O) end},
     {my_entitlement, fun(O) -> internetdata:my_entitlement(Client, O) end},
     {lookup_batch, fun(O) ->
         #{<<"1.1.1.1">> := Answer} = internetdata:lookup_batch(Client, [<<"1.1.1.1">>], O),
         Answer
     end}].

%% A dataset ID is caller input. Percent-encoded, it cannot escape the parameter
%% it was put in; unencoded, `x&id=y' would ask for a different dataset entirely.
a_dataset_id_cannot_rewrite_the_request_test() ->
    ?assertEqual(<<"bogon%2Fip%3Fx%3D1%26id%3Dother">>,
                 internetdata_http:escape(<<"bogon/ip?x=1&id=other">>)).

%% A 5xx is worth trying again; a 404 is the same answer however many times it is
%% asked. Held here as well as in the corpus because this is the endpoint whose
%% envelope differs.
a_server_fault_is_retried_and_a_missing_dataset_is_not_test() ->
    Faulty = internetdata_stub:start(#{?LIST_PATH => #{status => 503,
                                                       body => #{<<"rc">> => <<"NOT_AVAILABLE">>}}}),
    FaultyClient = internetdata:new(#{api_key => <<"k">>, retries => 2,
                                      http => internetdata_stub:http(Faulty)}),
    ?assertMatch({error, #{kind := server_error, retryable := true}},
                 internetdata:database_list(FaultyClient)),
    ?assertEqual(3, internetdata_stub:calls(Faulty)),
    internetdata_stub:stop(Faulty),

    Missing = internetdata_stub:start(#{}),
    MissingClient = internetdata:new(#{api_key => <<"k">>, retries => 2,
                                       http => internetdata_stub:http(Missing)}),
    ?assertMatch({error, #{kind := bad_request, status := 404, retryable := false}},
                 internetdata:database_metadata(MissingClient, <<"nope_v1">>)),
    ?assertEqual(1, internetdata_stub:calls(Missing)),
    internetdata_stub:stop(Missing).

%% Waited out as given, each of these would hold the call for weeks or for ever;
%% past ~24.8 days the client's own backoff is used instead, still a throttle.
a_retry_after_past_the_bound_is_waited_out_on_the_backoff_test_() ->
    [{binary_to_list(RetryAfter), fun() -> assert_backoff_used(RetryAfter) end}
     || RetryAfter <- [<<"2147484">>, <<"9223372036854775807">>, <<"Fri, 31 Dec 9999 23:59:59 GMT">>]].

%% The first answer throttles and the second serves. The call runs in a process
%% killed after 3 s, so a wait as long as the header fails rather than hangs.
assert_backoff_used(RetryAfter) ->
    Served = counters:new(1, []),
    Http = fun(_Request) ->
        counters:add(Served, 1, 1),
        case counters:get(Served, 1) of
            1 -> {ok, #{status => 429, headers => [{<<"retry-after">>, RetryAfter}], body => <<>>}};
            _ -> {ok, #{status => 200, headers => [], body => <<"{\"databases\":[]}">>}}
        end
    end,
    Client = internetdata:new(#{api_key => <<"k">>, retries => 1, http => Http}),
    Parent = self(),
    Caller = spawn(fun() -> Parent ! {self(), internetdata:database_list(Client)} end),

    Answer = receive
        {Caller, Result} -> Result
    after 3000 ->
        exit(Caller, kill),
        still_waiting_after_3s
    end,

    ?assertEqual({{ok, []}, 2}, {Answer, counters:get(Served, 1)}).

%% httpc acts on a 503's `Retry-After' itself unless told not to, and from OTP 28.4
%% waits out any value first, so each attempt would run to its 2 s timeout and fail
%% as `network'. Three characters, because OTP 27's httpc loops on one or two in a
%% way no client option stops, and leaves a longer value to the client.
a_503_carrying_retry_after_reaches_the_retry_policy_test_() ->
    {timeout, 60, fun() ->
        Origin = internetdata_origin:start(#{unavailable => <<"100">>}),
        Client = internetdata:new(#{base_url => internetdata_origin:base_url(Origin), api_key => <<"k">>,
                                    retries => 2, timeout_ms => 2000}),
        Calls = [{?LIST_PATH, fun() -> internetdata:database_list(Client) end},
                 {<<"/unavailable">>, fun() ->
                     internetdata:database_download_bytes(Client, <<"unavailable">>, mmdb)
                 end}],
        [begin
             {Micros, Answer} = timer:tc(Call),
             ?assertEqual({Path, 3}, {Path, internetdata_origin:hits(Origin, Path)}),
             ?assertMatch({Path, {error, #{kind := server_error, status := 503}}}, {Path, Answer}),
             ?assertEqual({Path, within}, {Path, within(Micros div 1000, {0, 1500})})
         end || {Path, Call} <- Calls],
        internetdata_origin:stop(Origin)
    end}.

%% An empty message says nothing, so it gives way to the next, then to the
%% status: it answered a refusal with a message of nothing at all. A lookup's
%% refusal says it in `error' and a database call's in `rc', and either call
%% reads both.
an_empty_message_gives_way_to_the_next_and_then_to_the_status_test_() ->
    Status = <<"request failed with status 403">>,
    Cases = [{#{<<"rc">> => <<"UNAUTHORIZED_ID">>}, <<"UNAUTHORIZED_ID">>},
             {#{<<"error">> => <<"source address not allowed for this API key">>},
              <<"source address not allowed for this API key">>},
             {#{<<"error">> => <<>>, <<"rc">> => <<"NOT_LICENSED">>}, <<"NOT_LICENSED">>},
             {#{<<"error">> => null, <<"rc">> => <<"UNAUTHORIZED_ID">>}, <<"UNAUTHORIZED_ID">>},
             {#{<<"rc">> => <<>>}, Status}, {#{<<"rc">> => null}, Status}, {#{<<"rc">> => 7}, Status},
             {#{<<"error">> => 7}, Status}, {#{}, Status}],
    Calls = [{?LIST_PATH, fun internetdata:database_list/1},
             {<<"/1.1.1.1">>, fun(C) -> internetdata:lookup(C, <<"1.1.1.1">>) end}],
    [{binary_to_list(iolist_to_binary([Path, " ", json:encode(Body)])), fun() ->
         Stub = internetdata_stub:start(#{Path => #{status => 403, body => Body}}),
         ?assertMatch({error, #{kind := forbidden, message := Want}}, Call(client(Stub))),
         internetdata_stub:stop(Stub)
     end} || {Body, Want} <- Cases, {Path, Call} <- Calls].

%% Digits, or an HTTP date in one of RFC 9110's three forms, in GMT, and nothing
%% else. httpd_util read any zone as GMT, a day that does not exist as one that
%% does or as a crash in the caller, and the digits took a sign.
a_retry_after_is_digits_or_an_http_date_and_nothing_else_test_() ->
    At = calendar:system_time_to_universal_time(erlang:system_time(second) + 60, second),
    {{Y, Mo, D}, {H, Mi, S}} = At,
    Day = lists:nth(calendar:day_of_the_week(Y, Mo, D), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]),
    Weekday = lists:nth(calendar:day_of_the_week(Y, Mo, D),
                        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]),
    Mon = lists:nth(Mo, ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]),
    Clock = io_lib:format("~2..0b:~2..0b:~2..0b", [H, Mi, S]),
    Imf = io_lib:format("~s, ~2..0b ~s ~b ~s", [Day, D, Mon, Y, Clock]),
    Next = Y + 1,
    Cases = [
        {"0", rate_limited}, {"120", rate_limited}, {" 7 ", rate_limited},
        {[Imf, " GMT"], rate_limited},
        {io_lib:format("~s, ~2..0b-~s-~2..0b ~s GMT", [Weekday, D, Mon, Y rem 100, Clock]), rate_limited},
        {io_lib:format("~s ~s ~2b ~s ~b", [Day, Mon, D, Clock, Y]), rate_limited},
        {[Imf, " +0000"], quota_exceeded}, {[Imf, " +0500"], quota_exceeded},
        {[Imf, " EST"], quota_exceeded}, {[Imf, " PST"], quota_exceeded}, {[Imf, " gmt"], quota_exceeded},
        {io_lib:format("~b-~2..0b-~2..0bT~sZ", [Y, Mo, D, Clock]), quota_exceeded},
        {io_lib:format("Xyz, ~2..0b ~s ~b ~s GMT", [D, Mon, Y, Clock]), quota_exceeded},
        {io_lib:format("~s, ~2..0b Foo ~b ~s GMT", [Day, D, Y, Clock]), quota_exceeded},
        {io_lib:format("~2..0b ~s ~b ~s GMT", [D, Mon, Y, Clock]), quota_exceeded},
        {io_lib:format("Tue, 31 Nov ~b 08:49:37 GMT", [Next]), quota_exceeded},
        {io_lib:format("Mon, 30 Feb ~b 08:49:37 GMT", [Next]), quota_exceeded},
        {io_lib:format("Fri, 01 Jan ~b 25:00:00 GMT", [Next]), quota_exceeded},
        {io_lib:format("Fri, 01 Jan ~b 25:61:61 GMT", [Next]), quota_exceeded},
        {io_lib:format("Fri, 01 Jan ~b 08:61:00 GMT", [Next]), quota_exceeded},
        {"1.5", quota_exceeded}, {"+1", quota_exceeded}, {"-1", quota_exceeded},
        {"0x10", quota_exceeded}, {"1_0", quota_exceeded}, {"1e3", quota_exceeded},
        {"tomorrow", quota_exceeded}, {"", quota_exceeded}
    ],
    [{lists:flatten(io_lib:format("Retry-After '~s'", [Value])), fun() -> assert_kind(Value, Kind) end}
     || {Value, Kind} <- Cases]
    ++ [{"a date is read as the seconds until it, in GMT", fun() ->
            {error, #{retry_after := Seconds}} = throttled(iolist_to_binary([Imf, " GMT"])),
            ?assert(Seconds >= 55 andalso Seconds =< 60)
        end},
        {"a date already past is a wait of nothing", fun() ->
            ?assertMatch({error, #{kind := rate_limited, retry_after := 0}},
                         throttled(<<"Sun, 06 Nov 1994 08:49:37 GMT">>))
        end}].

assert_kind(Value, Kind) ->
    ?assertMatch({error, #{kind := Kind}}, throttled(iolist_to_binary(Value))).

throttled(Value) ->
    Http = fun(_Request) ->
        {ok, #{status => 429, headers => [{<<"retry-after">>, Value}], body => <<>>}}
    end,
    internetdata:database_list(internetdata:new(#{api_key => <<"k">>, retries => 0, http => Http})).

%% `format()' checks nothing once compiled, so an atom from a flag or a config
%% file has to be refused at runtime, before it costs a request.
an_unpublished_format_is_refused_before_any_request_test() ->
    Stub = internetdata_stub:start(#{}),
    Client = client(Stub),
    Dir = list_to_binary(os:getenv("TMPDIR", "/tmp")),
    Path = <<Dir/binary, "/internetdata-", (integer_to_binary(erlang:unique_integer([positive])))/binary,
             "-refused.mmdb">>,
    Calls = [
        fun(F) -> internetdata:database_checksums(Client, <<"bogon_ip_v1">>, F) end,
        fun(F) -> internetdata:database_download_url(Client, <<"bogon_ip_v1">>, F) end,
        fun(F) -> internetdata:database_download(Client, <<"bogon_ip_v1">>, F, Path) end,
        fun(F) -> internetdata:database_download_bytes(Client, <<"bogon_ip_v1">>, F) end
    ],

    [?assertMatch({Format, {error, #{kind := bad_request, retryable := false}}},
                  {Format, Call(Format)})
     || Format <- [zip, 'MMDB', <<"mmdb">>, "csvgz"], Call <- Calls],
    ?assertEqual(0, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% The bound must cover the BODY: one that stops at the response head lets a body
%% stalled after its headers run for as long as the server likes.
a_body_stalled_after_its_headers_is_bounded_test_() ->
    {timeout, 60, fun() -> assert_body_bounded({stall, 8000}) end}.

%% A byte every 20 ms never leaves one read waiting long, so only a bound on the
%% whole attempt ends it.
a_body_trickled_a_byte_at_a_time_is_bounded_test_() ->
    {timeout, 60, fun() -> assert_body_bounded({trickle, 20}) end}.

%% The runtime lists are written by hand, so each is pinned to the committed spec
%% in BOTH directions: a value the spec gains or drops fails here on the re-pin.
the_exported_vocabularies_are_the_pinned_specs_test() ->
    ?assertEqual(lists:sort(spec_enum(<<"    DatabaseFormat:">>)),
                 lists:sort([atom_to_binary(F) || F <- internetdata:database_formats()])),
    ?assertEqual(lists:sort(spec_enum(<<"    Standing:">>)), lists:sort(internetdata:standings())),
    ?assertEqual(lists:sort(spec_license_types()), lists:sort(internetdata:license_types())).

%% The runtime list is written by hand, so it is pinned to the committed spec: a
%% format the spec gains fails here on the re-pin rather than being refused.
every_format_the_pinned_spec_publishes_is_accepted_test() ->
    Published = spec_formats(),
    ?assertNotEqual([], Published),
    Stub = internetdata_stub:start(#{?DOWNLOAD_PATH =>
        #{status => 302, headers => #{<<"Location">> => <<"https://storage.example/f">>}}}),
    Client = client(Stub),

    [?assertEqual({Format, {ok, <<"https://storage.example/f">>}},
                  {Format, internetdata:database_download_url(Client, <<"bogon_ip_v1">>,
                                                              binary_to_atom(Format))})
     || Format <- Published],
    ?assertEqual(length(Published), internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% The `DatabaseFormat' enum, read by line because OTP ships no YAML parser. The
%% schema's body is every line indented past its name, so another schema's enum
%% cannot be read in its place.
spec_formats() ->
    spec_enum(<<"    DatabaseFormat:">>).

spec_enum(SchemaLine) ->
    [_ | Rest] = lists:dropwhile(fun(Line) -> Line =/= SchemaLine end, spec_lines()),
    Schema = lists:takewhile(fun(Line) -> binary:match(Line, <<"      ">>) =:= {0, 6} end, Rest),
    [Value || <<"        - ", Value/binary>> <- Schema].

%% `license_type' is an inline enum on the family, nullable, so `null' is not one
%% of its values.
spec_license_types() ->
    [_ | Rest] = lists:dropwhile(fun(Line) -> Line =/= <<"        license_type:">> end, spec_lines()),
    Property = lists:takewhile(fun(Line) -> binary:match(Line, <<"          ">>) =:= {0, 10} end, Rest),
    [Value || <<"            - ", Value/binary>> <- Property, Value =/= <<"null">>].

spec_lines() ->
    {ok, Yaml} = file:read_file("spec/openapi.yaml"),
    binary:split(Yaml, <<"\n">>, [global]).

%% A call's own bound (300 ms) fires first, then every call with no override waits
%% for the client's (1 s), and the elapsed time says which one fired rather than
%% the stall ending on its own.
assert_body_bounded(Pace) ->
    Origin = internetdata_origin:start(#{body_pace => Pace}),
    Client = internetdata:new(#{base_url => internetdata_origin:base_url(Origin), api_key => <<"k">>,
                                cache => false, retries => 0, timeout_ms => 1000}),
    PerCall = #{timeout_ms => 300},
    Calls = [
        {lookup, {250, 900}, fun() -> internetdata:lookup(Client, <<"1.1.1.1">>, PerCall) end},
        {lookup_asn, {250, 900}, fun() -> internetdata:lookup_asn(Client, 9009, PerCall) end},
        {lookup_domain, {250, 900}, fun() -> internetdata:lookup_domain(Client, <<"example.com">>, PerCall) end},
        {lookup_batch, {250, 900}, fun() ->
            maps:get(<<"1.1.1.1">>, internetdata:lookup_batch(Client, [<<"1.1.1.1">>], PerCall))
        end},
        {database_downloads_per_call, {250, 900}, fun() ->
            internetdata:database_downloads(Client, #{limit => 5, timeout_ms => 300})
        end},
        {oauth_exchange, {250, 900}, fun() ->
            internetdata:oauth_exchange_device_code(Client, <<"cli">>, <<"mo_dc_x">>, #{timeout_ms => 300})
        end},
        {my_entitlement, {900, 2500}, fun() -> internetdata:my_entitlement(Client) end},
        {database_list, {900, 2500}, fun() -> internetdata:database_list(Client) end},
        {database_metadata, {900, 2500}, fun() ->
            internetdata:database_metadata(Client, <<"bogon_ip_v1">>)
        end},
        {database_downloads, {900, 2500}, fun() -> internetdata:database_downloads(Client, #{limit => 5}) end},
        {oauth_metadata, {900, 2500}, fun() -> internetdata:oauth_metadata(Client) end}
    ],
    [begin
         {Micros, Answer} = timer:tc(Call),
         ?assertMatch({Name, {error, #{kind := network, retryable := true}}}, {Name, Answer}),
         Ms = Micros div 1000,
         ?assertEqual({Name, within, Window}, {Name, within(Ms, Window), Window})
     end || {Name, Window, Call} <- Calls],
    internetdata_origin:stop(Origin).

is_bogon_is_on_the_client_and_agrees_with_the_standalone_export_test() ->
    Client = internetdata:new(#{cache => false, http => fun(_) -> {error, unused} end}),
    [?assertEqual({Ip, internetdata:is_bogon(Ip)}, {Ip, internetdata:is_bogon(Client, Ip)})
     || Ip <- [<<"10.0.0.1">>, <<"8.8.8.8">>, <<"fe80::1">>, <<"2606:4700:4700::1111">>]],
    ?assert(internetdata:is_bogon(Client, <<"192.168.1.1">>)),
    ?assertNot(internetdata:is_bogon(Client, "1.1.1.1")).

%% Asserting the PEAK is the only way to tell a real limit from an option that
%% was accepted and ignored.
batch_concurrency_is_configurable_per_call_test() ->
    Stub = internetdata_stub:start(routes(?ADDRS), 30),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => false}),

    _ = internetdata:lookup_batch(Client, ?ADDRS, #{concurrency => 3}),

    ?assertEqual(7, internetdata_stub:calls(Stub)),
    ?assert(internetdata_stub:peak(Stub) =< 3),
    ?assert(internetdata_stub:peak(Stub) > 1),
    internetdata_stub:stop(Stub).

a_per_call_concurrency_overrides_the_client_default_test() ->
    Stub = internetdata_stub:start(routes(?ADDRS), 30),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => false, concurrency => 2}),

    _ = internetdata:lookup_batch(Client, ?ADDRS, #{concurrency => 6}),

    ?assert(internetdata_stub:peak(Stub) > 2),
    ?assert(internetdata_stub:peak(Stub) =< 6),
    internetdata_stub:stop(Stub).

without_an_override_the_client_concurrency_still_applies_test() ->
    Stub = internetdata_stub:start(routes(?ADDRS), 30),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => false, concurrency => 2}),

    _ = internetdata:lookup_batch(Client, ?ADDRS),

    ?assertEqual(2, internetdata_stub:peak(Stub)),
    internetdata_stub:stop(Stub).

%% The stub proves the SDK spawns the right number of workers. This proves the
%% real transport then lets them all run.
the_real_transport_honors_the_concurrency_bound_test_() ->
    {timeout, 60, fun() ->
        Origin = internetdata_origin:start(#{delay_ms => 150}),
        %% Seventeen chunks of the batch endpoint's 1000, so sixteen workers each
        %% hold a request at once.
        Addrs = [addr(N) || N <- lists:seq(0, 16000)],
        Client = internetdata:new(#{base_url => internetdata_origin:base_url(Origin), cache => false}),

        Answers = internetdata:lookup_batch(Client, Addrs, #{concurrency => 16}),

        ?assertEqual(16, internetdata_origin:peak(Origin)),
        ?assertMatch({ok, #{ip := <<"9.1.0.0">>}}, maps:get(<<"9.1.0.0">>, Answers)),
        internetdata_origin:stop(Origin)
    end}.

%% A batch waits on its own workers' monitors only. A process running one with a
%% monitor of its own, as a gen_server often has, keeps that monitor's message.
a_batch_leaves_the_callers_own_monitors_alone_test() ->
    Stub = internetdata_stub:start(routes(?ADDRS), 30),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => false}),
    {Pid, Monitor} = spawn_monitor(fun() -> ok end),
    receive after 20 -> ok end,

    Answers = internetdata:lookup_batch(Client, [addr(0), addr(1)]),

    ?assertMatch(#{<<"9.1.0.0">> := {ok, _}, <<"9.1.0.1">> := {ok, _}}, Answers),
    ?assertEqual(kept, receive {'DOWN', Monitor, process, Pid, normal} -> kept after 0 -> lost end),
    internetdata_stub:stop(Stub).

retries_are_configurable_per_call_test() ->
    Stub = internetdata_stub:start(#{<<"9.9.9.9">> => #{status => 500,
                                                        body => #{<<"error">> => <<"lookup failed">>}}}),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => false, retries => 0}),

    ?assertMatch({error, #{kind := server_error}}, internetdata:lookup(Client, <<"9.9.9.9">>, #{retries => 2})),
    ?assertEqual(3, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

a_429_is_retried_only_when_it_carries_retry_after_test_() ->
    {timeout, 30, fun() ->
        WithHeader = internetdata_stub:start(#{
            <<"1.1.1.1">> => #{status => 429, headers => #{<<"Retry-After">> => <<"1">>},
                               body => #{<<"error">> => <<"rate limit exceeded">>}}}),
        Retried = internetdata:new(#{http => internetdata_stub:http(WithHeader), cache => false, retries => 1}),
        ?assertMatch({error, #{kind := rate_limited}}, internetdata:lookup(Retried, <<"1.1.1.1">>)),
        ?assertEqual(2, internetdata_stub:calls(WithHeader)),
        internetdata_stub:stop(WithHeader),

        Spent = internetdata_stub:start(#{
            <<"1.1.1.1">> => #{status => 429,
                               body => #{<<"error">> => <<"overage cap reached">>}}}),
        Once = internetdata:new(#{http => internetdata_stub:http(Spent), cache => false, retries => 3}),
        ?assertMatch({error, #{kind := quota_exceeded}}, internetdata:lookup(Once, <<"1.1.1.1">>)),
        ?assertEqual(1, internetdata_stub:calls(Spent)),
        internetdata_stub:stop(Spent)
    end}.

two_clients_never_share_a_cached_answer_test() ->
    Stub = internetdata_stub:start(routes([<<"1.1.1.1">>])),
    A = internetdata:new(#{http => internetdata_stub:http(Stub), api_key => <<"key-a">>}),
    B = internetdata:new(#{http => internetdata_stub:http(Stub), api_key => <<"key-b">>}),

    {ok, _} = internetdata:lookup(A, <<"1.1.1.1">>),
    {ok, _} = internetdata:lookup(B, <<"1.1.1.1">>),

    %% Two keys can be on different plans and so entitled to different fields; a
    %% shared cache would serve one of them the other's shape.
    ?assertEqual(2, internetdata_stub:calls(Stub)),
    internetdata:close(A),
    internetdata:close(B),
    internetdata_stub:stop(Stub).

caching_can_be_turned_off_test() ->
    Stub = internetdata_stub:start(routes([<<"1.1.1.1">>])),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => false}),

    {ok, _} = internetdata:lookup(Client, <<"1.1.1.1">>),
    {ok, _} = internetdata:lookup(Client, <<"1.1.1.1">>),

    ?assertEqual(2, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

a_cached_answer_expires_test() ->
    Stub = internetdata_stub:start(routes([<<"1.1.1.1">>])),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => #{ttl_ms => 50}}),

    {ok, _} = internetdata:lookup(Client, <<"1.1.1.1">>),
    {ok, _} = internetdata:lookup(Client, <<"1.1.1.1">>),
    ?assertEqual(1, internetdata_stub:calls(Stub)),

    timer:sleep(80),
    {ok, _} = internetdata:lookup(Client, <<"1.1.1.1">>),
    ?assertEqual(2, internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

the_cache_evicts_the_least_recently_used_entry_test() ->
    Addrs = [<<"9.9.9.1">>, <<"9.9.9.2">>, <<"9.9.9.3">>],
    Stub = internetdata_stub:start(routes(Addrs)),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => #{max => 2}}),

    {ok, _} = internetdata:lookup(Client, <<"9.9.9.1">>),
    {ok, _} = internetdata:lookup(Client, <<"9.9.9.2">>),
    {ok, _} = internetdata:lookup(Client, <<"9.9.9.1">>),
    {ok, _} = internetdata:lookup(Client, <<"9.9.9.3">>),
    ?assertEqual(3, internetdata_stub:calls(Stub)),

    %% 9.9.9.2 was the least recently used when 9.9.9.3 arrived, so it is the one
    %% that had to be fetched again; 9.9.9.1 is still held.
    {ok, _} = internetdata:lookup(Client, <<"9.9.9.1">>),
    ?assertEqual(3, internetdata_stub:calls(Stub)),
    {ok, _} = internetdata:lookup(Client, <<"9.9.9.2">>),
    ?assertEqual(4, internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

errors_are_never_cached_test() ->
    Stub = internetdata_stub:start(#{<<"1.1.1.1">> => #{status => 500,
                                                        body => #{<<"error">> => <<"lookup failed">>}}}),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), retries => 0}),

    {error, _} = internetdata:lookup(Client, <<"1.1.1.1">>),
    {error, _} = internetdata:lookup(Client, <<"1.1.1.1">>),

    ?assertEqual(2, internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

%% The API answers an AS or a domain at an address's path, in a shape a lookup
%% cannot read, so a lookup refuses anything else before sending it, and says
%% which call to make instead. A batch sends what it is given, and the API refuses
%% a non-address entry by entry.
a_lookup_refuses_text_that_is_no_ip_address_before_sending_it_test() ->
    Stub = internetdata_stub:start(routes([<<"1.1.1.1">>, <<"2606:4700:4700::1111">>, <<"8.8.8.8">>])),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), retries => 2}),

    [begin
         {error, #{kind := Kind, retryable := Retryable, message := Message}} = internetdata:lookup(Client, Text),
         ?assertEqual({Text, bad_request, false}, {Text, Kind, Retryable}),
         ?assertNotEqual({Text, nomatch}, {Text, binary:match(Message, <<"lookup_asn/2">>)}),
         ?assertNotEqual({Text, nomatch}, {Text, binary:match(Message, <<"lookup_domain/2">>)})
     end || Text <- [<<"example.com">>, <<"AS9009">>, <<"9009">>, "9009", <<>>, <<"1.2.3">>, <<"8.8.8.888">>,
                     <<"1.1.1.1/24">>, <<" 1.1.1.1">>, <<"notanip">>, <<255, 0>>]],
    ?assertEqual(0, internetdata_stub:calls(Stub)),
    ?assertMatch({error, #{kind := bad_request}},
                 internetdata:lookup(Client, <<"example.com">>, #{timeout_ms => 0})),

    [?assertMatch({Ip, {ok, _}}, {Ip, internetdata:lookup(Client, Ip)})
     || Ip <- [<<"1.1.1.1">>, "2606:4700:4700::1111", <<"::ffff:8.8.8.8">>]],
    ?assertEqual(3, internetdata_stub:calls(Stub)),
    #{<<"example.com">> := {error, #{kind := bad_request, status := 400}}} =
        internetdata:lookup_batch(Client, [<<"example.com">>]),
    ?assertEqual(4, internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

%% A detail requires no member and is `{}' under a false flag: either is an
%% answer, handed back as served.
a_detail_is_handed_back_as_served_test() ->
    Partial = #{<<"provider">> => <<"mullvad">>},
    Stub = internetdata_stub:start(#{<<"1.1.1.1">> => #{body => (lookup_ok())#{<<"vpn">> => Partial,
                                                                               <<"hosting">> => #{}}}}),

    {ok, Result} = internetdata:lookup(client(Stub), <<"1.1.1.1">>),

    ?assertEqual(#{provider => <<"mullvad">>}, maps:get(vpn, Result)),
    ?assertEqual(#{}, maps:get(hosting, Result)),
    internetdata_stub:stop(Stub).

%% Every request goes to the client's base URL, whatever host the spec names for
%% an operation: this lookup, AS and domain are served by a local origin.
a_lookup_is_served_from_the_clients_own_base_url_test_() ->
    {timeout, 30, fun() ->
        Origin = internetdata_origin:start(#{}),
        Client = internetdata:new(#{base_url => internetdata_origin:base_url(Origin), cache => false}),

        ?assertMatch({ok, #{ip := <<"1.1.1.1">>}}, internetdata:lookup(Client, <<"1.1.1.1">>)),
        ?assertMatch({ok, #{ip := <<"203.0.113.9">>}}, internetdata:my_ip(Client)),
        ?assertMatch({ok, #{asn := 9009}}, internetdata:lookup_asn(Client, 9009)),
        ?assertMatch({ok, #{domain := <<"example.com">>}}, internetdata:lookup_domain(Client, <<"example.com">>)),
        [?assertEqual({Path, 1}, {Path, internetdata_origin:hits(Origin, Path)})
         || Path <- [<<"/1.1.1.1">>, <<"/myip">>, <<"/asn/9009">>, <<"/domain/example.com">>]],
        internetdata_origin:stop(Origin)
    end}.

%% The AS and domain answers are not cached, and neither are the self-endpoints:
%% which address a call comes from IS the question, and what a key has spent is
%% wrong within seconds.
the_as_domain_and_self_answers_are_never_cached_test() ->
    Stub = internetdata_stub:start(#{<<"/asn/9009">> => #{body => asn_ok()},
                                     <<"/domain/example.com">> => #{body => domain_ok()},
                                     <<"/myip">> => #{body => lookup_ok()},
                                     ?ENTITLEMENT_PATH => #{body => entitlement_ok()}}),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), api_key => <<"k">>}),

    [{ok, _} = Call() || _ <- [1, 2],
                         Call <- [fun() -> internetdata:lookup_asn(Client, 9009) end,
                                  fun() -> internetdata:lookup_domain(Client, <<"example.com">>) end,
                                  fun() -> internetdata:my_ip(Client) end,
                                  fun() -> internetdata:my_entitlement(Client) end]],

    ?assertEqual(8, internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

%% The AS number and the domain go on the path as given, the domain escaped, so
%% a stray `/' or `?' cannot rewrite the request; the API normalizes both.
the_as_and_domain_are_sent_as_given_test() ->
    Parent = self(),
    Http = fun(#{url := Url}) ->
        Parent ! {requested, Url},
        Refusal = #{<<"error">> => <<"not a valid IP address, AS number or domain">>},
        {ok, #{status => 400, headers => [], body => iolist_to_binary(json:encode(Refusal))}}
    end,
    Client = internetdata:new(#{http => Http, retries => 2}),

    [?assertMatch({error, #{kind := bad_request, status := 400,
                            message := <<"not a valid IP address, AS number or domain">>}}, Call())
     || Call <- [fun() -> internetdata:lookup_asn(Client, 9009) end,
                 fun() -> internetdata:lookup_asn(Client, 4294967295) end,
                 fun() -> internetdata:lookup_domain(Client, <<"example.com">>) end,
                 fun() -> internetdata:lookup_domain(Client, "Example.COM") end,
                 fun() -> internetdata:lookup_domain(Client, <<"b", 16#C3, 16#BC, "cher.de">>) end,
                 fun() -> internetdata:lookup_domain(Client, <<"a/b?c=d">>) end]],

    ?assertEqual([<<"https://api.internetdata.io/asn/9009">>, <<"https://api.internetdata.io/asn/4294967295">>,
                  <<"https://api.internetdata.io/domain/example.com">>,
                  <<"https://api.internetdata.io/domain/Example.COM">>,
                  <<"https://api.internetdata.io/domain/b%C3%BCcher.de">>,
                  <<"https://api.internetdata.io/domain/a%2Fb%3Fc%3Dd">>],
                 requested([])),
    ?assertError(badarg, internetdata:lookup_asn(Client, <<"AS9009">>)).

%% An AS answer's `whois' is keyed by the registry's own field names, so those
%% stay binaries while the documented members become atoms.
an_as_answers_whois_keeps_the_registrys_names_test() ->
    Stub = internetdata_stub:start(#{<<"/asn/9009">> => #{body => asn_ok()}}),

    {ok, As} = internetdata:lookup_asn(client(Stub), 9009),

    ?assertEqual(9009, maps:get(asn, As)),
    ?assertEqual(#{<<"abuse_email">> => <<"abuse@m247.ro">>, <<"org">> => <<"ORG-MES6-RIPE">>},
                 maps:get(whois, As)),
    [Prefix] = maps:get(prefixes, As),
    ?assertEqual([9009], maps:get(other_origins, Prefix)),
    internetdata_stub:stop(Stub).

%% The atom table is capped and never collected, so a lookup answer carrying keys
%% nothing in the library mentions must not be able to grow it, at any depth.
a_lookup_full_of_unknown_keys_mints_no_atoms_test() ->
    Client = internetdata:new(#{cache => false, http => fun(#{url := Url}) ->
        Ip = lists:last(binary:split(Url, <<"/">>, [global])),
        Wire = internetdata_stub:answer(Ip),
        {ok, #{status => 200, headers => [], body => iolist_to_binary(json:encode(
            Wire#{<<"surprise_", Ip/binary>> => #{<<"nested_", Ip/binary>> => 1},
                  <<"location">> => (maps:get(<<"location">>, Wire))#{<<"deep_", Ip/binary>> => 1}}))}}
    end}),
    {ok, _} = internetdata:lookup(Client, <<"9.9.9.1">>),

    Before = erlang:system_info(atom_count),
    [{ok, _} = internetdata:lookup(Client, <<"9.9.9.", (integer_to_binary(N))/binary>>)
     || N <- lists:seq(100, 160)],
    ?assertEqual(Before, erlang:system_info(atom_count)).

a_transport_failure_is_an_error_not_a_crash_test() ->
    Client = internetdata:new(#{base_url => <<"http://127.0.0.1:1">>, cache => false,
                                retries => 0, timeout_ms => 2000}),
    ?assertMatch({error, #{kind := network, retryable := true}}, internetdata:lookup(Client, <<"1.1.1.1">>)).

%% The per-call bound is set BELOW the client's against an origin that stalls
%% past both, so a call that ignored it would wait out the client's bound
%% instead, and the elapsed time says which one fired.
a_per_call_timeout_below_the_clients_is_the_one_that_fires_test_() ->
    {timeout, 60, fun() ->
        Origin = internetdata_origin:start(#{delay_ms => 8000}),
        Client = internetdata:new(#{base_url => internetdata_origin:base_url(Origin),
                                    cache => false, retries => 0, timeout_ms => 4000}),
        [begin
             {Micros, Answer} = timer:tc(fun() -> Call(#{timeout_ms => 300}) end),
             ?assertMatch({Name, {error, #{kind := network, retryable := true}}}, {Name, Answer}),
             ?assertEqual({Name, within}, {Name, within(Micros div 1000, {0, 2000})})
         end || {Name, Call} <- per_call(Client)],
        internetdata_origin:stop(Origin)
    end}.

%% Duplicates, and the spellings of one IPv4-mapped address, collapse before
%% anything is sent, so each address rides in its chunk once.
a_batch_sends_each_address_once_test() ->
    Stub = internetdata_stub:start(routes([<<"1.1.1.1">>, <<"8.8.8.8">>])),
    Http = internetdata_stub:http(Stub),
    Parent = self(),
    Recording = fun(Request) ->
        Parent ! {sent_ips, maps:get(<<"ips">>, json:decode(maps:get(body, Request)))},
        Http(Request)
    end,
    Client = internetdata:new(#{http => Recording, cache => false}),

    Got = internetdata:lookup_batch(Client, [<<"1.1.1.1">>, <<"8.8.8.8">>, <<"1.1.1.1">>, <<"::ffff:1.1.1.1">>,
                                             {1, 1, 1, 1}]),

    ?assertEqual([<<"1.1.1.1">>, <<"8.8.8.8">>], lists:sort(receive {sent_ips, Ips} -> Ips after 1000 -> none end)),
    ?assertEqual([<<"1.1.1.1">>, <<"8.8.8.8">>, <<"::ffff:1.1.1.1">>], lists:sort(maps:keys(Got))),
    ?assertEqual(1, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% No cap on what one call accepts: chunking to the endpoint's 1000 is the
%% client's job, so 2,500 addresses are three requests rather than an error.
a_batch_of_2500_addresses_is_three_requests_and_one_answer_each_test() ->
    Addrs = [addr(N) || N <- lists:seq(0, 2499)],
    Stub = internetdata_stub:start(routes(Addrs)),
    Http = internetdata_stub:http(Stub),
    Parent = self(),
    Recording = fun(#{method := Method, url := Url} = Request) ->
        Ips = maps:get(<<"ips">>, json:decode(maps:get(body, Request, <<"{}">>)), []),
        Parent ! {sent, Method, maps:get(path, uri_string:parse(Url)), length(Ips)},
        Http(Request)
    end,
    Client = internetdata:new(#{http => Recording, cache => false}),

    Got = internetdata:lookup_batch(Client, Addrs),

    ?assertEqual([{post, <<"/batch">>, 500}, {post, <<"/batch">>, 1000}, {post, <<"/batch">>, 1000}],
                 lists:sort(sent([]))),
    ?assertEqual(2500, map_size(Got)),
    [?assertMatch({ok, #{ip := Ip}}, maps:get(Ip, Got)) || Ip <- Addrs],
    internetdata_stub:stop(Stub).

%% A dispatcher that may run nothing waits for ever, so a concurrency below 1 is
%% refused before any request, for every address it was given, and a client's
%% where it is built, as its retries and timeout are.
a_batch_concurrency_below_one_is_refused_before_any_request_test() ->
    Stub = internetdata_stub:start(#{}),
    Http = internetdata_stub:http(Stub),
    Client = internetdata:new(#{http => Http, cache => false}),
    Ips = [<<"9.9.9.9">>, <<"10.0.0.1">>],

    [?assertEqual({Limit, lists:sort(Ips), [bad_request, bad_request]},
                  {Limit, lists:sort(maps:keys(Got)), [Kind || {error, #{kind := Kind}} <- maps:values(Got)]})
     || Limit <- [0, -1, 1.5],
        Got <- [internetdata:lookup_batch(Client, Ips, #{concurrency => Limit})]],
    [?assertError({badarg, {concurrency, Limit}},
                  internetdata:new(#{http => Http, cache => false, concurrency => Limit}))
     || Limit <- [0, -1, 1.5, 2.0, nan, infinity, <<"2">>, "2", make_ref()]],
    [?assertMatch(#{concurrency := Limit}, internetdata:new(#{http => Http, cache => false, concurrency => Limit}))
     || Limit <- [1, 64]],
    ?assertEqual(0, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

my_ip_classifies_the_calling_address_test() ->
    Stub = internetdata_stub:start(#{<<"/myip">> => #{body => (internetdata_stub:answer(<<"45.83.91.1">>))#{
        <<"is_vpn">> => true}}}),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub)}),

    {ok, Result} = internetdata:my_ip(Client),

    ?assertEqual(<<"45.83.91.1">>, maps:get(ip, Result)),
    ?assertEqual(true, maps:get(is_vpn, Result)),
    ?assertEqual(false, maps:get(is_bogon, Result)),
    internetdata_stub:stop(Stub).

my_entitlement_reports_the_plan_and_the_usage_test() ->
    Stub = internetdata_stub:start(#{?ENTITLEMENT_PATH => #{body => entitlement_ok()}}),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub)}),

    {ok, Account} = internetdata:my_entitlement(Client),

    ?assertEqual(<<"max">>, maps:get(key, maps:get(plan, Account))),
    ?assertEqual(<<"max">>, maps:get(tier, maps:get(plan, Account))),
    Usage = maps:get(usage, Account),
    ?assertEqual(580, maps:get(requests, Usage)),
    ?assertEqual(5000000, maps:get(quota, Usage)),
    %% null means NEVER stop, which is not the same as a limit of zero.
    ?assertEqual(null, maps:get(hard_limit, Usage)),
    ?assertEqual([], maps:get(allowed_cidrs, maps:get(apikey, Account))),
    internetdata_stub:stop(Stub).

%% Unlike a lookup there is no useful unauthenticated answer.
my_entitlement_surfaces_an_unauthorized_key_test() ->
    Stub = internetdata_stub:start(#{?ENTITLEMENT_PATH =>
        #{status => 401, body => #{<<"error">> => <<"an API key is required">>}}}),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), retries => 0}),

    ?assertMatch({error, #{kind := unauthorized, message := <<"an API key is required">>}},
                 internetdata:my_entitlement(Client)),
    internetdata_stub:stop(Stub).

%% `inet:peername/1' and Cowboy's `peer' give an address as a tuple.
an_address_given_as_a_tuple_is_looked_up_as_its_text_test() ->
    Parent = self(),
    Http = fun(#{url := Url}) ->
        Parent ! {url, Url},
        Ip = uri_string:percent_decode(lists:last(binary:split(Url, <<"/">>, [global]))),
        {ok, #{status => 200, headers => [], body => iolist_to_binary(json:encode(internetdata_stub:answer(Ip)))}}
    end,
    Client = internetdata:new(#{http => Http, cache => false}),
    Sent = fun() ->
        receive {url, Url} -> uri_string:percent_decode(lists:last(binary:split(Url, <<"/">>, [global])))
        after 1000 -> nothing_sent
        end
    end,
    {ok, _} = internetdata:lookup(Client, {45, 83, 91, 1}),
    ?assertEqual(<<"45.83.91.1">>, Sent()),
    {ok, _} = internetdata:lookup(Client, {16#2606, 16#4700, 16#4700, 0, 0, 0, 0, 16#1111}),
    ?assertEqual(<<"2606:4700:4700::1111">>, Sent()),
    %% A bogon tuple is answered locally, as its text is.
    {ok, Bogon} = internetdata:lookup(Client, {10, 0, 0, 1}),
    ?assertEqual(<<"10.0.0.1">>, maps:get(ip, Bogon)),
    ?assertEqual(nothing_sent, Sent()),
    ?assertEqual([<<"10.0.0.1">>, <<"45.83.91.1">>],
                 lists:sort(maps:keys(internetdata:lookup_batch(Client, [{45, 83, 91, 1}, {10, 0, 0, 1}])))),
    [?assertError({badarg, {ip, Bad}}, internetdata:lookup(Client, Bad))
     || Bad <- [{1, 2, 3}, {256, 0, 0, 1}, {-1, 0, 0, 1}]].

%% A linked process ends with an exiting owner only on an abnormal exit, so the
%% cache also monitors the process that built the client.
a_cache_ends_with_the_process_that_built_it_test() ->
    Parent = self(),
    [begin
         Owner = spawn(fun() ->
             Parent ! {client, internetdata:new(#{http => fun(_) -> {error, unused} end})},
             receive go -> exit(Reason) end
         end),
         Client = receive {client, C} -> C after 1000 -> error(no_client) end,
         #{cache := #{pid := Cache}} = Client,
         Monitor = erlang:monitor(process, Cache),
         Owner ! go,
         ?assertEqual({Reason, down}, {Reason, receive {'DOWN', Monitor, process, Cache, _} -> down
                                                after 1000 -> still_running end})
     end || Reason <- [normal, shutdown, kill]].

%% A batch entry of the wrong shape is that address's error alone, sent once.
a_batch_entry_of_the_wrong_shape_fails_that_address_alone_test() ->
    Sent = counters:new(1, []),
    Good = internetdata_stub:answer(<<"9.9.9.9">>),
    Body = iolist_to_binary(json:encode(#{<<"results">> => #{
        <<"1.1.1.1">> => (internetdata_stub:answer(<<"1.1.1.1">>))#{<<"dcproxy">> => #{<<"hits">> => <<"3">>}},
        <<"8.8.8.8">> => maps:remove(<<"location">>, internetdata_stub:answer(<<"8.8.8.8">>)),
        <<"9.9.9.9">> => Good}})),
    Http = fun(_) -> counters:add(Sent, 1, 1), {ok, #{status => 200, headers => [], body => Body}} end,
    Client = internetdata:new(#{api_key => <<"k">>, retries => 2, http => Http, cache => false}),
    Answers = internetdata:lookup_batch(Client, [<<"1.1.1.1">>, <<"8.8.8.8">>, <<"9.9.9.9">>]),
    ?assertEqual(1, counters:get(Sent, 1)),
    ?assertMatch({error, #{kind := server_error, status := 200}}, maps:get(<<"1.1.1.1">>, Answers)),
    ?assertMatch({error, #{kind := server_error, status := 200}}, maps:get(<<"8.8.8.8">>, Answers)),
    ?assertMatch({ok, #{ip := <<"9.9.9.9">>}}, maps:get(<<"9.9.9.9">>, Answers)).

%% One entry the batch cannot read is that address's error alone; the rest of the
%% chunk is answered, and nothing is sent again.
a_batch_entry_that_cannot_be_read_fails_only_its_address_test() ->
    Sent = counters:new(1, []),
    Results = #{<<"1.1.1.1">> => internetdata_stub:answer(<<"1.1.1.1">>), <<"2.2.2.2">> => 7},
    Body = iolist_to_binary(json:encode(#{<<"results">> => Results, <<"errors">> => #{}})),
    Http = fun(_Request) ->
        counters:add(Sent, 1, 1),
        {ok, #{status => 200, headers => [], body => Body}}
    end,
    Client = internetdata:new(#{api_key => <<"k">>, retries => 2, http => Http, cache => false}),

    Answers = internetdata:lookup_batch(Client, [<<"1.1.1.1">>, <<"2.2.2.2">>]),
    ?assertMatch(#{<<"1.1.1.1">> := {ok, #{ip := <<"1.1.1.1">>}},
                   <<"2.2.2.2">> := {error, #{kind := server_error, status := 200}}}, Answers),
    ?assertEqual(1, counters:get(Sent, 1)).

%% Every call but OAuth goes to the API host, the database's included, which
%% answers there as it does on the apex.
the_default_base_url_is_the_api_host_test() ->
    Parent = self(),
    Http = fun(#{url := Url}) ->
        Parent ! {requested, Url},
        {ok, #{status => 404, headers => [], body => <<"{}">>}}
    end,
    Client = internetdata:new(#{http => Http, retries => 0}),

    _ = internetdata:lookup(Client, <<"1.1.1.1">>),
    _ = internetdata:my_ip(Client),
    _ = internetdata:my_entitlement(Client),
    _ = internetdata:lookup_batch(Client, [<<"1.1.1.1">>, <<"8.8.8.8">>]),
    _ = internetdata:database_list(Client),
    _ = internetdata:oauth_metadata(Client),

    ?assertEqual([<<"https://api.internetdata.io/1.1.1.1">>, <<"https://api.internetdata.io/myip">>,
                  <<"https://api.internetdata.io/api/v1/entitlement">>, <<"https://api.internetdata.io/batch">>,
                  <<"https://api.internetdata.io/api/v2/database/list">>,
                  <<"https://internetdata.io/.well-known/oauth-authorization-server">>],
                 requested([])).

%% The authorization server is the apex the API host sits under, so `api.' is
%% dropped and `api-<env>.' becomes `<env>.'; any other base URL is used as given.
oauth_goes_to_the_apex_of_an_api_host_test_() ->
    Cases = [{<<"https://api.internetdata.io">>, <<"https://internetdata.io">>},
             {<<"https://api-staging.internetdata.io/">>, <<"https://staging.internetdata.io">>},
             {<<"https://api-dev-2.internetdata.io">>, <<"https://dev-2.internetdata.io">>},
             {<<"HTTPS://API.internetdata.io">>, <<"HTTPS://internetdata.io">>},
             {<<"https://internetdata.io">>, <<"https://internetdata.io">>},
             {<<"https://staging.internetdata.io">>, <<"https://staging.internetdata.io">>},
             {<<"https://apis.example">>, <<"https://apis.example">>},
             {<<"https://myapi.example">>, <<"https://myapi.example">>},
             {<<"http://127.0.0.1:8080">>, <<"http://127.0.0.1:8080">>},
             {<<"https://proxy.example/api.internetdata.io">>, <<"https://proxy.example/api.internetdata.io">>}],
    [{binary_to_list(Base), fun() ->
         Parent = self(),
         Http = fun(#{url := Url}) ->
             Parent ! {requested, Url},
             {ok, #{status => 404, headers => [], body => <<"{}">>}}
         end,
         Client = internetdata:new(#{base_url => Base, http => Http, retries => 0}),
         _ = internetdata:oauth_metadata(Client),
         _ = internetdata:oauth_device_authorization(Client, <<"cli">>),
         _ = internetdata:database_list(Client),
         {ok, Url} = internetdata:oauth_authorization_url(Client, <<"cli">>, <<"http://127.0.0.1/cb">>, <<"c">>),
         Api = trim(Base),
         ?assertEqual([<<Apex/binary, "/.well-known/oauth-authorization-server">>,
                       <<Apex/binary, "/oauth/device_authorization">>, <<Api/binary, "/api/v2/database/list">>],
                      requested([])),
         ?assertMatch(<<Apex:(byte_size(Apex))/binary, "/oauth/authorize?", _/binary>>, Url)
     end} || {Base, Apex} <- Cases].

trim(Url) ->
    string:trim(Url, trailing, "/").

sent(Acc) ->
    receive
        {sent, Method, Path, Size} -> sent([{Method, Path, Size} | Acc])
    after 0 ->
        Acc
    end.

requested(Acc) ->
    receive
        {requested, Url} -> requested([Url | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

path_and_query(Url) ->
    Parsed = uri_string:parse(Url),
    {maps:get(path, Parsed), uri_string:dissect_query(maps:get(query, Parsed, <<>>))}.

within(Ms, {Low, High}) when Ms >= Low, Ms < High -> within;
within(Ms, _Window) -> {took_ms, Ms}.

family() ->
    #{
        <<"base">> => <<"bogon_ip">>,
        <<"name">> => <<"Bogon IP">>,
        <<"summary">> => <<"Unroutable address space">>,
        <<"standing">> => <<"licensed">>,
        <<"open">> => true,
        <<"license_type">> => <<"redistribute">>,
        <<"starts">> => <<"2026-01-01T00:00:00.000Z">>,
        <<"expires">> => null,
        <<"versions">> => [#{<<"id">> => <<"bogon_ip_v1">>, <<"version">> => 1,
                             <<"summary">> => <<"v1">>,
                             <<"formats">> => [<<"csvgz">>, <<"mmdb">>]}]
    }.

metadata() ->
    #{
        <<"id">> => <<"bogon_ip_v1">>,
        <<"update_freq">> => <<"daily">>,
        <<"updated">> => <<"2026-09-04">>,
        <<"entries">> => 42,
        <<"schema">> => #{<<"csvgz">> => [#{<<"name">> => <<"range_start">>,
                                            <<"type">> => <<"varchar">>,
                                            <<"description">> => <<"first address">>}]},
        <<"sample">> => #{<<"csvgz">> => [#{<<"range_start">> => <<"10.0.0.0">>,
                                            <<"range_end">> => <<"10.255.255.255">>}]},
        <<"size">> => #{<<"csvgz">> => 760, <<"mmdb">> => 3524}
    }.

download() ->
    #{<<"dataset_id">> => <<"bogon_ip_v1">>, <<"format">> => <<"csvgz">>, <<"outcome">> => <<"ok">>,
      <<"sample">> => false, <<"open">> => true, <<"bytes">> => 760, <<"http_status">> => 200,
      <<"apikey_id">> => <<"key_1">>, <<"client_ip">> => <<"203.0.113.7">>, <<"user_agent">> => <<"ua">>,
      <<"created">> => <<"2026-09-04T10:00:00.000Z">>}.

client(Stub) ->
    internetdata:new(#{api_key => <<"k">>, http => internetdata_stub:http(Stub)}).

addr(N) ->
    list_to_binary(io_lib:format("9.~b.~b.~b", [1 + N div 65536, (N div 256) rem 256, N rem 256])).

routes(Addrs) ->
    maps:from_list([{Ip, #{body => internetdata_stub:answer(Ip)}} || Ip <- Addrs]).

%% A paid answer carrying every member, each detail populated.
lookup_ok() ->
    Class = #{<<"provider">> => <<"mullvad">>, <<"provider_name">> => <<"Mullvad">>, <<"confidence">> => <<"high">>,
              <<"last_seen">> => <<"2026-11-13">>},
    Proxy = #{<<"provider">> => <<"p">>, <<"provider_name">> => <<"P">>, <<"first_seen">> => <<"2026-10-01">>,
              <<"last_seen">> => <<"2026-11-13">>, <<"hits">> => 3, <<"hits_days_pct">> => 10,
              <<"providers_num">> => 1},
    Web = #{<<"port">> => 443, <<"tls_ok">> => true, <<"session_ok">> => true, <<"status_code">> => 301,
            <<"server">> => <<"s">>, <<"location">> => <<"https://example.com/">>, <<"title">> => <<>>,
            <<"cert_subject_cn">> => <<"cn">>, <<"cert_subject_o">> => <<"o">>, <<"cert_issuer_dn">> => <<"dn">>,
            <<"cert_browser_trusted">> => true, <<"tls_version">> => <<"TLSv1.3">>,
            <<"first_seen">> => <<"2026-08-12">>, <<"last_seen">> => <<"2026-10-31">>},
    Wire = internetdata_stub:answer(<<"1.1.1.1">>),
    Wire#{<<"is_vpn">> => true, <<"is_resproxy">> => false, <<"is_dcproxy">> => true, <<"is_mobproxy">> => false,
          <<"is_pubproxy">> => true, <<"is_hosting">> => true, <<"is_cdn">> => false, <<"is_web">> => true,
          <<"vpn">> => Class, <<"hosting">> => Class, <<"cdn">> => #{}, <<"resproxy">> => #{},
          <<"dcproxy">> => Proxy, <<"mobproxy">> => #{},
          <<"pubproxy">> => #{<<"entry">> => true, <<"exit">> => false, <<"protocols">> => [<<"http">>],
                              <<"num_ports">> => 2, <<"num_proxies">> => 0, <<"last_seen">> => <<"2026-11-13">>,
                              <<"last_usable">> => <<>>},
          <<"carrier">> => #{}, <<"satellite">> => #{}, <<"ssh">> => #{}, <<"smtp">> => #{}, <<"web">> => [Web],
          <<"dns_resolver">> => #{}, <<"bittorrent">> => #{},
          <<"location">> => (maps:get(<<"location">>, Wire))#{<<"city">> => <<"Vienna">>, <<"latitude">> => 48.2,
                                                              <<"longitude">> => 16, <<"accuracy_radius">> => 20},
          <<"asn">> => (maps:get(<<"asn">>, Wire))#{<<"rpki_status">> => <<"valid">>, <<"country">> => <<"AT">>},
          <<"company">> => (maps:get(<<"company">>, Wire))#{<<"type">> => <<"hosting">>, <<"country">> => <<"AT">>},
          <<"abuse">> => #{<<"email">> => <<"a@example.com">>, <<"phone">> => <<>>, <<"validated">> => false},
          <<"whois">> => #{<<"id">> => <<"i">>, <<"name">> => <<"n">>, <<"org">> => <<"o">>,
                           <<"country">> => <<"AT">>, <<"status">> => <<"s">>, <<"source">> => <<"ripe">>,
                           <<"domain">> => <<"d">>, <<"abuse_email">> => <<"a@example.com">>, <<"asn">> => 9009},
          <<"rwhois">> => maps:from_keys([<<"id">>, <<"name">>, <<"country">>, <<"source">>, <<"domain">>,
                                          <<"abuse_email">>], <<>>),
          <<"hosted_domains">> => #{<<"total">> => 0}, <<"trial_expired">> => false}.

asn_ok() ->
    #{<<"asn">> => 9009, <<"name">> => <<"M247 Europe SRL">>, <<"country">> => <<"RO">>,
      <<"registry">> => <<"ripe">>, <<"allocated">> => <<"2005-06-06">>, <<"domain">> => <<"m247global.com">>,
      <<"type">> => <<"hosting">>,
      <<"num_ips">> => 1615872, <<"num_prefixes4">> => 4510, <<"num_prefixes6">> => 807, <<"rpki_valid">> => 2972,
      <<"rpki_invalid">> => 50, <<"rpki_not_found">> => 2295,
      <<"whois">> => #{<<"abuse_email">> => <<"abuse@m247.ro">>, <<"org">> => <<"ORG-MES6-RIPE">>},
      <<"prefixes">> => [#{<<"prefix">> => <<"146.70.116.0/24">>, <<"peer_count">> => 12,
                           <<"rpki_status">> => <<"not_found">>, <<"first_seen">> => <<"2021-03-02">>,
                           <<"country">> => <<"AT">>, <<"size">> => 256, <<"other_origins">> => [9009]}],
      <<"trial_expired">> => false}.

domain_ok() ->
    Seen = <<"2026-11-08">>,
    #{<<"domain">> => <<"example.com">>, <<"is_registered">> => true, <<"is_disposable">> => false,
      <<"has_a">> => true, <<"has_aaaa">> => false, <<"has_mx">> => true, <<"has_ns">> => true,
      <<"has_cname">> => false,
      <<"dns">> => #{<<"a">> => [#{<<"ip">> => <<"192.0.2.10">>, <<"last_seen">> => Seen}], <<"aaaa">> => [],
                     <<"mx">> => [#{<<"priority">> => 10, <<"host">> => <<"mail.example.com">>,
                                    <<"last_seen">> => Seen}],
                     <<"ns">> => [#{<<"host">> => <<"ns1.example.com">>, <<"last_seen">> => Seen}],
                     <<"cname">> => []},
      <<"ip_ranges">> => #{<<"domain">> => <<"example.com">>, <<"redirects_to">> => <<>>, <<"total">> => 1,
                           <<"ipv4">> => 256,
                           <<"ranges">> => [#{<<"range">> => <<"192.0.2.0/24">>, <<"name">> => <<"EXAMPLE-NET">>,
                                              <<"country">> => <<"US">>}]},
      <<"disposable">> => #{}, <<"trial_expired">> => false}.

entitlement_ok() ->
    #{<<"org_id">> => <<"85bb51e4-2eb6-4a31-8e4d-02ba8b98fe61">>,
      <<"apikey">> => #{<<"id">> => <<"0ab424cc-7619-4dad-b027-afacdc2cedb0">>, <<"expires">> => null,
                        <<"allowed_cidrs">> => []},
      <<"plan">> => #{<<"key">> => <<"max">>, <<"tier">> => <<"max">>},
      <<"usage">> => #{<<"requests">> => 580, <<"quota">> => 5000000, <<"hard_limit">> => null,
                       <<"window_start">> => <<"2026-09-04T07:00:00Z">>,
                       <<"window_end">> => <<"2026-10-04T07:00:00Z">>}}.

entitlement_at(<<"expires">>, Value) ->
    Wire = entitlement_ok(),
    Wire#{<<"apikey">> => (maps:get(<<"apikey">>, Wire))#{<<"expires">> => Value}};
entitlement_at(Member, Value) ->
    Wire = entitlement_ok(),
    Wire#{<<"usage">> => (maps:get(<<"usage">>, Wire))#{Member => Value}}.
