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
    ?assertEqual([<<"csvgz">>, <<"mmdb">>],
                 maps:get(formats, hd(maps:get(versions, Database)))),
    ?assertEqual(<<"bogon_ip_v1">>, maps:get(id, hd(maps:get(versions, Database)))),
    internetdata_stub:stop(Stub).

an_envelope_that_is_missing_is_reported_rather_than_guessed_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"datasets">> => []}}}),
    Client = client(Stub),

    ?assertMatch({error, #{kind := server_error, retryable := false}},
                 internetdata:database_list(Client)),
    internetdata_stub:stop(Stub).

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
                <<"outcome">> => <<"denied">>, <<"bytes">> => null,
                <<"http_status">> => 403, <<"apikey_id">> => null,
                <<"client_ip">> => <<"203.0.113.7">>, <<"user_agent">> => null,
                <<"created">> => <<"2026-09-04T10:00:00.000Z">>},
    Stub = internetdata_stub:start(#{?DOWNLOADS_PATH => #{body => #{<<"downloads">> => [Attempt]}}}),
    Client = client(Stub),

    {ok, [Download]} = internetdata:database_downloads(Client),

    ?assertEqual(<<"denied">>, maps:get(outcome, Download)),
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

a_body_that_is_not_json_is_not_a_crash_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{raw => <<"<html>nope</html>">>}}),
    Client = client(Stub),

    ?assertMatch({error, #{kind := server_error, retryable := false}},
                 internetdata:database_list(Client)),
    internetdata_stub:stop(Stub).

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

client(Stub) ->
    internetdata:new(#{api_key => <<"k">>, http => internetdata_stub:http(Stub)}).
