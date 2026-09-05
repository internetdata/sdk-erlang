%% @doc Turns a decoded JSON body into the maps the client hands back.
%%
%% <b>Only a name the SPEC defines, at the POSITION the spec defines it, becomes
%% an atom.</b> Everything else keeps its binary key. That is not a style
%% preference: `schema', `sample' and `size' are keyed by format, and the rows
%% under `sample' are keyed by the dataset's own column names, all of which are
%% the server's to choose. Erlang's atom table is capped at 1,048,576 entries and
%% is never garbage collected, so minting an atom per key off a body like that is
%% a remote VM kill rather than a leak.
%%
%% The consequence to read the results by: `maps:get(base, Db)' for a documented
%% field, `maps:get(&lt;&lt;"csvgz"&gt;&gt;, Size)' for anything keyed by format or by a
%% dataset column.
-module(internetdata_result).

-export([databases/1, metadata/1, checksums/1, downloads/1]).

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
key(database, <<"redistribution">>) -> redistribution;
key(database, <<"starts">>) -> starts;
key(database, <<"expires">>) -> expires;
key(database, <<"versions">>) -> versions;
key(version, <<"id">>) -> id;
key(version, <<"version">>) -> version;
key(version, <<"summary">>) -> summary;
key(version, <<"formats">>) -> formats;
key(metadata, <<"id">>) -> id;
key(metadata, <<"update_freq">>) -> update_freq;
key(metadata, <<"updated">>) -> updated;
key(metadata, <<"entries">>) -> entries;
key(metadata, <<"schema">>) -> schema;
key(metadata, <<"sample">>) -> sample;
key(metadata, <<"size">>) -> size;
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
key(download, <<"bytes">>) -> bytes;
key(download, <<"http_status">>) -> http_status;
key(download, <<"apikey_id">>) -> apikey_id;
key(download, <<"client_ip">>) -> client_ip;
key(download, <<"user_agent">>) -> user_agent;
key(download, <<"created">>) -> created;
key(_Context, _Name) -> undefined.

%% VALUES are never turned into atoms either, however closed the spec's enum
%% looks: `standing', `redistribution', `outcome' and `format' are all documented
%% as open on purpose, so a value added later stays readable by a client written
%% today. They arrive as binaries and stay that way.
child(database, <<"versions">>, Versions) when is_list(Versions) ->
    [decode(version, Version) || Version <- Versions];
%% Keyed by format, so the outer keys stay binary and only the columns under them
%% are documented names.
child(metadata, <<"schema">>, Schema) when is_map(Schema) ->
    maps:map(fun(_Format, Columns) -> columns(Columns) end, Schema);
child(_Context, _Name, Value) ->
    Value.

columns(Columns) when is_list(Columns) ->
    [decode(column, Column) || Column <- Columns];
columns(Other) ->
    Other.
