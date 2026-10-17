%% The client's own contract: what reaches the wire, how deep each response is
%% unwrapped, and which keys are allowed to become atoms.
-module(internetdata_client_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LIST_PATH, <<"/api/v2/database/list">>).
-define(METADATA_PATH, <<"/api/v2/database/metadata">>).
-define(CHECKSUM_PATH, <<"/api/v2/database/checksum">>).
-define(DOWNLOADS_PATH, <<"/api/v2/database/downloads">>).
-define(DOWNLOAD_PATH, <<"/api/v2/database/download">>).
-define(INVALID_TIMEOUTS, [0, -1, 1.5, foo, 4294967296, 1 bsl 64]).

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

    _ = internetdata:database_list(Client),
    _ = internetdata:oauth_metadata(Client),
    _ = internetdata:oauth_device_authorization(Client, <<"cli">>),

    ?assertEqual([<<Base/binary, "/api/v2/database/list">>,
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
    Calls = [{?LIST_PATH, <<"databases">>, fun internetdata:database_list/1},
             {?METADATA_PATH, <<"id">>, fun(C) -> internetdata:database_metadata(C, <<"bogon_ip_v1">>) end},
             {?CHECKSUM_PATH, <<"checksums">>,
              fun(C) -> internetdata:database_checksums(C, <<"bogon_ip_v1">>, mmdb) end},
             {?DOWNLOADS_PATH, <<"downloads">>, fun internetdata:database_downloads/1}],
    WrongTypes = [{?LIST_PATH, <<"{\"databases\":{}}">>}, {?LIST_PATH, <<"{\"databases\":null}">>},
                  {?LIST_PATH, <<"{\"databases\":[1]}">>}, {?CHECKSUM_PATH, <<"{\"checksums\":[]}">>},
                  {?DOWNLOADS_PATH, <<"{\"downloads\":{}}">>}, {?DOWNLOADS_PATH, <<"{\"downloads\":[null]}">>},
                  {?METADATA_PATH, <<"{\"id\":null}">>}],
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
%% without the members the spec requires as an empty map (1.10.0).
a_member_of_the_wrong_type_at_any_depth_is_a_retried_server_error_test_() ->
    Family = family(),
    [Version] = maps:get(<<"versions">>, Family),
    Listing = fun(F) -> #{<<"databases">> => [F]} end,
    Attempt = download(),
    Sums = #{<<"md5">> => <<"m">>, <<"sha1">> => <<"s1">>, <<"sha256">> => <<"s256">>, <<"sha512">> => <<"s512">>},
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
        {?CHECKSUM_PATH, #{<<"checksums">> => Sums#{<<"sha256">> => 1}}},
        {?CHECKSUM_PATH, #{<<"checksums">> => maps:remove(<<"sha512">>, Sums)}},
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

%% A per-call bound httpc cannot wait on is refused as well, before it costs a
%% request.
a_per_call_timeout_out_of_range_is_refused_before_any_request_test() ->
    Stub = internetdata_stub:start(#{?DOWNLOADS_PATH => #{body => #{<<"downloads">> => []}}}),
    Client = client(Stub),

    [?assertMatch({V, {error, #{kind := bad_request, retryable := false}}},
                  {V, internetdata:database_downloads(Client, #{timeout_ms => V})})
     || V <- ?INVALID_TIMEOUTS],
    ?assertEqual(0, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% A dataset id is caller input. Percent-encoded, it cannot escape the parameter
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

%% An empty code says nothing, so it gives way to the status: it answered a
%% refusal with a message of nothing at all.
an_empty_result_code_gives_way_to_the_status_test_() ->
    Status = <<"request failed with status 403">>,
    Cases = [{#{<<"rc">> => <<"UNAUTHORIZED_ID">>}, <<"UNAUTHORIZED_ID">>}, {#{<<"rc">> => <<>>}, Status},
             {#{<<"rc">> => null}, Status}, {#{<<"rc">> => 7}, Status}, {#{}, Status}],
    [{binary_to_list(iolist_to_binary(json:encode(Body))), fun() ->
         Stub = internetdata_stub:start(#{?LIST_PATH => #{status => 403, body => Body}}),
         ?assertMatch({error, #{kind := forbidden, message := Want}}, internetdata:database_list(client(Stub))),
         internetdata_stub:stop(Stub)
     end} || {Body, Want} <- Cases].

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
                                retries => 0, timeout_ms => 1000}),
    Calls = [
        {database_downloads_per_call, {250, 900}, fun() ->
            internetdata:database_downloads(Client, #{limit => 5, timeout_ms => 300})
        end},
        {oauth_exchange, {250, 900}, fun() ->
            internetdata:oauth_exchange_device_code(Client, <<"cli">>, <<"mo_dc_x">>, #{timeout_ms => 300})
        end},
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
