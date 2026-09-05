%% The client's own contract: what reaches the wire, how deep each response is
%% unwrapped, and which keys are allowed to become atoms.
-module(internetdata_client_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LIST_PATH, <<"/api/v2/database/list">>).
-define(METADATA_PATH, <<"/api/v2/database/metadata">>).
-define(CHECKSUM_PATH, <<"/api/v2/database/checksum">>).
-define(DOWNLOADS_PATH, <<"/api/v2/database/downloads">>).

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
%% the default stay the server's to change.
a_limit_is_only_sent_when_it_is_asked_for_test() ->
    Stub = internetdata_stub:start(#{?DOWNLOADS_PATH => #{body => #{<<"downloads">> => []}}}),
    Client = client(Stub),

    {ok, []} = internetdata:database_downloads(Client),
    {ok, []} = internetdata:database_downloads(Client, #{limit => 200}),

    ?assertEqual(2, internetdata_stub:calls(Stub)),
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

a_body_that_is_not_json_is_not_a_crash_test() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{raw => <<"<html>nope</html>">>}}),
    Client = client(Stub),

    ?assertMatch({error, #{kind := server_error, retryable := false}},
                 internetdata:database_list(Client)),
    internetdata_stub:stop(Stub).

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
