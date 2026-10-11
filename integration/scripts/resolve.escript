#!/usr/bin/env escript
%% -*- erlang -*-

%% The questions scripts/run.sh has to answer before it can trust a run, all
%% written in Erlang because the files involved ARE Erlang terms: rebar.config
%% holds the dependency and rebar.lock holds what was resolved, and consulting
%% them beats a grep that a reformat would quietly defeat.
%%
%%   resolve.escript package     the package name rebar.config depends on
%%   resolve.escript published   the versions on hex that satisfy rebar.config,
%%                               ascending, one per line; nothing at all when the
%%                               package or a matching version does not exist
%%   resolve.escript resolved    what rebar.lock says the dependency came from,
%%                               as `pkg <version>', `other <term>' or `missing'
%%   resolve.escript checksum    fails unless the tarball rebar.lock records is
%%                               the one hex.pm publishes for that version
%%
%% Nothing here names the package: it is read from rebar.config, so the gate and
%% the resolver cannot disagree about what is being asked for, and pointing the
%% whole thing at a package that IS published is a one-line edit to a scratch
%% copy - which is the only way to exercise the non-skip path before a first
%% release.
%%
%% An empty `published' is a SKIP and not a failure: before the first release
%% there is no artifact to test. Anything else that goes wrong exits non-zero,
%% so a network fault cannot be mistaken for an unpublished package.

main(["package"]) ->
    {Name, _Constraint} = dep(),
    io:format("~s~n", [Name]);
main(["published"]) ->
    {Name, Constraint} = dep(),
    io:format(standard_error, "==> ~s ~s~n", [Name, Constraint]),
    [io:format("~s~n", [V]) || V <- matching(Constraint, releases(Name))];
main(["resolved"]) ->
    {Name, _Constraint} = dep(),
    io:format("~s~n", [locked(Name)]);
main(["checksum"]) ->
    {Name, _Constraint} = dep(),
    checksum(Name);
main(_) ->
    die("usage: resolve.escript package|published|resolved|checksum").

%% Exactly one dependency, and it is the package under test. More than one would
%% make "the constraint" ambiguous, so it fails rather than picking.
dep() ->
    {ok, Terms} = file:consult("rebar.config"),
    case proplists:get_value(deps, Terms, []) of
        [{Name, Constraint}] when is_atom(Name) ->
            {atom_to_list(Name), text(Constraint)};
        Other ->
            die(io_lib:format("rebar.config declares ~p, which is not a single hex dependency",
                              [Other]))
    end.

text(Constraint) when is_list(Constraint) -> Constraint;
text(Constraint) when is_binary(Constraint) -> binary_to_list(Constraint);
text(Other) -> die(io_lib:format("~p is not a hex constraint", [Other])).

%% hex's own package API, which lists exactly the releases its repository serves,
%% so this is the set `rebar3' would resolve from. A 404 means the package has
%% never been published, which is the state before the first release.
releases(Name) ->
    case api(["/packages/", Name]) of
        {200, Body} -> [V || #{<<"version">> := V} <- maps:get(<<"releases">>, json:decode(Body), [])];
        {404, _} -> []
    end.

%% rebar3 checks a tarball against the registry it came from, and records its
%% checksum in rebar.lock; that registry is hex.pm's only if nothing in rebar3's
%% configuration names another, which the lock does not say. So the checksum is
%% held to the one hex.pm's API lists for the release.
checksum(Name) ->
    {Vsn, Locked} = locked_checksum(Name),
    Published = case api(["/packages/", Name, "/releases/", Vsn]) of
        {200, Body} -> maps:get(<<"checksum">>, json:decode(Body), undefined);
        {404, _} -> undefined
    end,
    case is_binary(Published) andalso string:lowercase(Published) =:= Locked of
        true ->
            io:format("==> ~s-~s.tar is the tarball hex.pm publishes, sha256 ~s~n", [Name, Vsn, Locked]);
        false ->
            die(io_lib:format("the ~s-~s.tar rebar3 resolved has sha256 ~s where hex.pm publishes ~p, "
                              "so it is not the released package", [Name, Vsn, Locked, Published]))
    end.

api(Path) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    Url = lists:flatten(["https://hex.pm/api" | Path]),
    Request = {Url, [{"user-agent", "internetdata-sdk-integration"}, {"accept", "application/json"}]},
    case httpc:request(get, Request, [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, Body}} when Status =:= 200; Status =:= 404 ->
            {Status, Body};
        {ok, {{_, Status, _}, _, _}} ->
            die(io_lib:format("hex answered ~b for ~s", [Status, Url]));
        {error, Reason} ->
            die(io_lib:format("could not reach hex: ~p", [Reason]))
    end.

matching(Constraint, Releases) ->
    {Low, High} = bounds(Constraint),
    Versions = [parse(V) || V <- Releases, binary:match(V, [<<"-">>, <<"+">>]) =:= nomatch],
    [render(V) || V <- lists:sort([V || V <- Versions, V >= Low, High =:= any orelse V < High])].

%% `~>' is the only operator this suite needs, so anything else fails loudly
%% rather than matching nothing and reading as "not published yet".
bounds("~>" ++ Rest) ->
    Raw = string:trim(Rest),
    {parse(Raw), ceiling(components(Raw))};
bounds(Exact) ->
    case parse(string:trim(Exact)) of
        [_ | _] = Version -> {Version, Version ++ [1]};
        _ -> die(["unsupported constraint ", Exact])
    end.

%% Padded to three components so 1.0 and 1.0.0 COMPARE equal, which is what hex
%% means by them.
parse(Version) when is_binary(Version) ->
    parse(binary_to_list(Version));
parse(Version) ->
    Parts = [list_to_integer(P) || P <- string:lexemes(Version, ".")],
    Parts ++ lists:duplicate(erlang:max(0, 3 - length(Parts)), 0).

%% hex reads `~>' off the number of components WRITTEN, not off the padded value:
%% `~> 1.0' admits every 1.x, while `~> 1.0.0' stops before 1.1.0. Padding to
%% three and then incrementing the second-to-last component collapses those two,
%% so `~> 1.0' would stop matching the day 1.1.0 ships and this gate would skip
%% for ever - indistinguishable from "nothing published yet", which is the one
%% failure it must never imitate.
components(Raw) ->
    [list_to_integer(P) || P <- string:lexemes(Raw, ".")].

ceiling([Major]) -> [Major + 1, 0, 0];
ceiling([Major, _Minor]) -> [Major + 1, 0, 0];
ceiling([Major, Minor, _Patch]) -> [Major, Minor + 1, 0];
ceiling(Other) ->
    die(io_lib:format("~b-component constraint is not one hex defines", [length(Other)])).

render(Version) ->
    lists:join(".", [integer_to_list(P) || P <- Version]).

%% rebar.lock names the SOURCE, not just the version. A hex package locks as
%% `{pkg, Name, Vsn}'; a `{path, ...}' dependency is not locked at all and a git
%% one locks as `{git, ...}', so the shape is what proves the tests will run
%% against a release rather than against the source next door.
locked(Name) ->
    case file:consult("rebar.lock") of
        {ok, Terms} -> entry(Name, deps(Terms));
        {error, enoent} -> "missing"
    end.

deps([{_Version, Deps} | _]) -> Deps;
deps([Deps | _]) when is_list(Deps) -> Deps;
deps(_) -> [].

entry(Name, Deps) ->
    case lists:keyfind(list_to_binary(Name), 1, Deps) of
        {_, {pkg, _, Vsn}, _} -> ["pkg ", Vsn];
        {_, Source, _} -> io_lib:format("other ~p", [Source]);
        false -> "missing"
    end.

%% The version locked and the outer checksum beside it, the sha256 of the whole
%% tarball, which is what hex's API lists as a release's checksum.
locked_checksum(Name) ->
    {ok, Terms} = file:consult("rebar.lock"),
    Key = list_to_binary(Name),
    Hashes = lists:append([proplists:get_value(pkg_hash_ext, T, []) || T <- Terms, is_list(T)]),
    case {lists:keyfind(Key, 1, deps(Terms)), lists:keyfind(Key, 1, Hashes)} of
        {{_, {pkg, _, Vsn}, _}, {_, Hash}} -> {binary_to_list(Vsn), string:lowercase(Hash)};
        _ -> die(io_lib:format("rebar.lock records no package checksum for ~s", [Name]))
    end.

die(Message) ->
    io:format(standard_error, "FAILED: ~s~n", [Message]),
    halt(1).
