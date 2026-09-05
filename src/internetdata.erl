%% @doc The official Erlang client for the InternetData database API.
%%
%% Build a client once with {@link new/1} and pass the term around. It holds no
%% process and no socket of its own, so there is nothing to release. Every call
%% answers `{ok, Term}' or `{error, Error}'; nothing here raises for a failure
%% the API can report.
%%
%% Results are maps keyed by ATOMS for the fields the API documents, and by
%% BINARIES for anything the server names: the format keys under `schema',
%% `sample' and `size', and the dataset column names inside a sample row. See
%% {@link internetdata_result} for why.
%%
%% <b>The catalog is not the same for everyone.</b> A dataset commissioned for a
%% single customer is simply ABSENT from {@link database_list/1} for anybody
%% else, rather than listed with an `unlicensed' standing. Read the listing this
%% client returns; do not cache one and reuse it under a different key, and do
%% not assemble a catalog from anywhere else.
-module(internetdata).

-export([new/1]).
-export([database_list/1, database_metadata/2, database_checksums/3,
         database_downloads/1, database_downloads/2, database_download_url/3,
         database_download/4, database_download_bytes/3]).

-export_type([client/0, options/0, downloads_options/0, format/0]).

-define(DEFAULT_BASE_URL, <<"https://internetdata.io">>).
-define(DEFAULT_RETRIES, 2).
-define(DEFAULT_TIMEOUT_MS, 30000).

-opaque client() :: #{
    base_url := binary(),
    api_key := binary(),
    retries := non_neg_integer(),
    timeout_ms := pos_integer(),
    user_agent := binary(),
    http := internetdata_http:http_fun()
}.

-type options() :: #{
    api_key := binary() | string(),
    base_url => binary() | string(),
    retries => non_neg_integer(),
    timeout_ms => pos_integer(),
    http => internetdata_http:http_fun()
}.

-type downloads_options() :: #{limit => pos_integer()}.
-type format() :: csvgz | mmdb.

%% @doc Build a client.
%%
%% `api_key' is required: every endpoint here is authenticated, so a client built
%% without one could only ever answer 401. Create a key in the console with the
%% `db.download' scope. Keys are default-deny, so an existing key does not gain
%% database access until that scope is added to it.
-spec new(options()) -> client().
new(Options) ->
    case maps:is_key(http, Options) of
        false -> internetdata_http:ensure_ready();
        true -> ok
    end,
    #{
        base_url => bin(maps:get(base_url, Options, ?DEFAULT_BASE_URL)),
        api_key => api_key(Options),
        retries => maps:get(retries, Options, ?DEFAULT_RETRIES),
        timeout_ms => maps:get(timeout_ms, Options, ?DEFAULT_TIMEOUT_MS),
        user_agent => user_agent(),
        http => maps:get(http, Options, internetdata_http:httpc_fun())
    }.

%% @doc Every dataset FAMILY your organization may see, and where each one
%% stands.
%%
%% The whole published catalog, not only what you license: `standing' says
%% whether a family is yours today (`&lt;&lt;"licensed"&gt;&gt;'), was
%% (`&lt;&lt;"expired"&gt;&gt;'), or has never been bought
%% (`&lt;&lt;"unlicensed"&gt;&gt;'). Families built for one customer are not listed
%% to anybody else at all, so what comes back depends on the key that asked.
%%
%% A license covers a family (`base'), while a download names one of its
%% versions, so the ids the other calls take come from a family's `versions'
%% rather than from the family itself.
-spec database_list(client()) -> {ok, [map()]} | {error, internetdata_error:error()}.
database_list(Client) ->
    case unwrap(get_json(Client, <<"/api/v2/database/list">>, []), <<"databases">>) of
        {ok, Databases} -> {ok, internetdata_result:databases(Databases)};
        {error, Error} -> {error, Error}
    end.

%% @doc What is inside one dataset: column schema and sample rows per format, the
%% row count, the byte size of each artifact, and the day it was built.
%%
%% Answered from the top level of the response rather than from an envelope, and
%% cheap enough to poll: `updated' and `entries' say whether today's build is
%% worth fetching without moving any of it. `size' is what to check a transfer
%% against before starting one - the catalog spans five orders of magnitude.
-spec database_metadata(client(), binary() | string()) ->
    {ok, map()} | {error, internetdata_error:error()}.
database_metadata(Client, Id) ->
    case get_json(Client, <<"/api/v2/database/metadata">>, [{<<"id">>, bin(Id)}]) of
        {ok, Body} -> {ok, internetdata_result:metadata(Body)};
        {error, Error} -> {error, Error}
    end.

%% @doc Every digest published for one dataset file.
%%
%% The whole set, not one algorithm: which digests a dataset publishes is the
%% API's choice rather than ours, and they arrive nested under `checksums'.
-spec database_checksums(client(), binary() | string(), format()) ->
    {ok, map()} | {error, internetdata_error:error()}.
database_checksums(Client, Id, Format) ->
    Query = [{<<"id">>, bin(Id)}, {<<"format">>, atom_to_binary(Format)}],
    case unwrap(get_json(Client, <<"/api/v2/database/checksum">>, Query), <<"checksums">>) of
        {ok, Checksums} -> {ok, internetdata_result:checksums(Checksums)};
        {error, Error} -> {error, Error}
    end.

-spec database_downloads(client()) -> {ok, [map()]} | {error, internetdata_error:error()}.
database_downloads(Client) ->
    database_downloads(Client, #{}).

%% @doc Your organization's recent download attempts, newest first.
%%
%% Refusals are listed too: a denial is what answers "it stopped working", and
%% its absence answers nothing. `limit' defaults to 50 and the API clamps it
%% to 200.
-spec database_downloads(client(), downloads_options()) ->
    {ok, [map()]} | {error, internetdata_error:error()}.
database_downloads(Client, Options) ->
    Query = case maps:find(limit, Options) of
        {ok, Limit} -> [{<<"limit">>, integer_to_binary(Limit)}];
        error -> []
    end,
    case unwrap(get_json(Client, <<"/api/v2/database/downloads">>, Query), <<"downloads">>) of
        {ok, Downloads} -> {ok, internetdata_result:downloads(Downloads)};
        {error, Error} -> {error, Error}
    end.

%% @doc The time-limited URL for one dataset file.
%%
%% The API answers a 302 straight to object storage and this reads the `Location'
%% without following it, so what comes back is a link that carries NO credential
%% of yours and can be handed to whatever does the transfer. It authorizes the
%% START of a transfer, so one already running is not interrupted when it lapses.
-spec database_download_url(client(), binary() | string(), format()) ->
    {ok, binary()} | {error, internetdata_error:error()}.
database_download_url(Client, Id, Format) ->
    Query = [{<<"id">>, bin(Id)}, {<<"format">>, atom_to_binary(Format)}],
    internetdata_http:get_redirect(Client, <<"/api/v2/database/download">>, Query,
                                   maps:get(retries, Client)).

%% @doc Download one dataset file to `Path', and answer how many bytes landed.
%%
%% The transfer is streamed, so nothing beyond a single chunk is ever held in
%% memory whatever the dataset weighs. The bytes go to a neighboring `.part' file
%% that is renamed only once the whole body has arrived: a transfer that dies
%% halfway leaves neither a truncated file that reads as a complete dataset nor a
%% `.part' for the next attempt to append to.
%%
%% The client's `timeout_ms' bounds the wait between chunks here rather than the
%% whole transfer, because a deadline that suits a listing is the wrong one for a
%% gigabyte while a stalled transfer is stalled at any size.
-spec database_download(client(), binary() | string(), format(), binary() | string()) ->
    {ok, non_neg_integer()} | {error, internetdata_error:error()}.
database_download(Client, Id, Format, Path) ->
    Dest = bin(Path),
    Partial = <<Dest/binary, ".part">>,
    case file:open(Partial, [write, binary, raw]) of
        {ok, Fd} -> to_file(Client, Id, Format, Dest, Partial, Fd);
        {error, Reason} -> {error, io_error(Partial, Reason)}
    end.

%% @doc Download one dataset file and hand back its bytes.
%%
%% This holds the ENTIRE file in memory, and the published catalog runs from a
%% few hundred bytes to several gigabytes, so reach for it at the small end and
%% use {@link database_download/4} for anything you have not checked
%% {@link database_metadata/2} for first. It transfers over exactly the same
%% streamed path, so the bytes are the ones {@link database_download/4} would
%% have written.
-spec database_download_bytes(client(), binary() | string(), format()) ->
    {ok, binary()} | {error, internetdata_error:error()}.
database_download_bytes(Client, Id, Format) ->
    Sink = #{fold => fun(Chunk, Chunks) -> {ok, [Chunk | Chunks]} end, acc => []},
    case transfer(Client, Id, Format, Sink) of
        {ok, #{acc := Chunks}} -> {ok, iolist_to_binary(lists:reverse(Chunks))};
        {error, Error} -> {error, Error}
    end.

to_file(Client, Id, Format, Dest, Partial, Fd) ->
    Sink = #{acc => Fd, fold => fun(Chunk, Handle) ->
        case file:write(Handle, Chunk) of
            ok -> {ok, Handle};
            {error, Reason} -> {error, message(Partial, Reason)}
        end
    end},
    Transferred = transfer(Client, Id, Format, Sink),
    Closed = file:close(Fd),
    case {Transferred, Closed} of
        {{ok, #{written := Written}}, ok} ->
            rename(Partial, Dest, Written);
        %% A close that fails is a write that failed: with the file gone the
        %% count says nothing, so this is a failure rather than a short success.
        {{ok, _}, {error, Reason}} ->
            discard(Partial),
            {error, io_error(Dest, Reason)};
        {{error, Error}, _} ->
            discard(Partial),
            {error, Error}
    end.

%% The 302 is followed as a SECOND request that carries no credential: the
%% presigned link authorizes itself, and forwarding the API key would hand it to
%% a host with no business holding it.
transfer(Client, Id, Format, Sink) ->
    case database_download_url(Client, Id, Format) of
        {ok, Url} -> internetdata_http:get_stream(Client, Url, Sink, maps:get(retries, Client));
        {error, Error} -> {error, Error}
    end.

rename(Partial, Dest, Written) ->
    case file:rename(Partial, Dest) of
        ok ->
            {ok, Written};
        {error, Reason} ->
            discard(Partial),
            {error, io_error(Dest, Reason)}
    end.

discard(Partial) ->
    _ = file:delete(Partial),
    ok.

io_error(Path, Reason) ->
    #{kind => io, retryable => false, message => message(Path, Reason)}.

message(Path, Reason) ->
    iolist_to_binary([Path, ": ", file:format_error(Reason)]).

get_json(Client, Path, Query) ->
    internetdata_http:get_json(Client, Path, Query, maps:get(retries, Client)).

unwrap({ok, Body}, Key) ->
    case Body of
        #{Key := Value} -> {ok, Value};
        _ -> {error, #{kind => server_error, retryable => false,
                       message => <<"response did not carry a \"", Key/binary, "\" member">>}}
    end;
unwrap({error, Error}, _Key) ->
    {error, Error}.

%% A missing key is the caller's mistake rather than the API's, and every call
%% this client makes needs one, so it fails here instead of turning every request
%% into a 401.
api_key(Options) ->
    case maps:get(api_key, Options, undefined) of
        undefined -> error({missing_option, api_key});
        Key -> bin(Key)
    end.

user_agent() ->
    Version = case application:get_key(internetdata, vsn) of
        {ok, Vsn} -> list_to_binary(Vsn);
        undefined -> <<"dev">>
    end,
    <<"internetdata-erlang/", Version/binary>>.

bin(Value) when is_binary(Value) -> Value;
bin(Value) when is_list(Value) -> list_to_binary(Value).
